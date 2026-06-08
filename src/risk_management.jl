# ============================================
# 期货交易风控模块 (RiskManagement)
# ============================================
# 功能：
#   1. 风控模块初始化 (rm_init)
#      - 通过 RMConfig.rules 直接传入类型化风控规则（代码配置模式）
#   2. 下单前风控检查 (rm_order)
#      - 批量委托逐条过风控规则，短路拦截
#   3. 行情触发紧急风控 (rm_price)
#      - 行情快照驱动，触发后调用 create_risk_close_task 创建清仓任务，
#        由执行引擎负责撤单与平仓
#
# 风控类型（每类对应一个 AbstractRMRule 子类型）：
#   1 - 频繁委托风控 (FrequentOrderRule)
#       同一策略下委托后到收到委托/成交回报之前禁止下任何新委托
#   2 - 最大回撤风控 (MaxDrawbackRule)
#       基于历史净值序列计算策略级最大回撤，超过阈值则触发紧急清仓
#   3 - 当日最大亏损资金风控 (MaxLossRule)
#       监控策略当日权益相对日初权益的亏损金额（×10000 后的整数），超过阈值则触发紧急清仓
#   4 - 风险度风控 (RiskRateRule)
#       监控策略的保证金占用比（margin / equity），超过阈值则触发紧急清仓
#   5 - 最大平仓风控 (MaxCloseRule)
#       平仓前校验可用持仓是否充足，持仓不足则拦截
#   6 - 最大资金风控 (MaxCapitalRule)
#       开仓前校验可用资金是否充足，资金不足则拦截
# ============================================

# ============================================
# 常量定义
# ============================================

# 风控类型
const RM_TYPE_FREQUENT_ORDER = 1
const RM_TYPE_MAX_DRAWBACK   = 2
const RM_TYPE_MAX_LOSS       = 3
const RM_TYPE_RISK_RATE      = 4
const RM_TYPE_MAX_CLOSE      = 5
const RM_TYPE_MAX_CAPITAL    = 6

# 持锁耗时告警阈值（毫秒）
# rm_order / rm_price 等热路径的 lock(rm_lock) 块若包含 lock 等待 + 持有 + 释放
# 累计耗时超过此阈值，写一条 warn 日志，便于定位风控模块性能瓶颈。
# 正常生产环境应远低于此值（< 10ms）。
const RM_LOCK_WARN_MS = 20

# ============================================
# 数据结构
# ============================================
# 最大回撤状态
mutable struct DrawbackState
    history_netvalue::Float64
    history_max_netvalue::Float64
    history_drawback::Float64
end

abstract type AbstractRMRule end

# 返回风控类型编号（用于日志和结果报告）
rmtype_id(::AbstractRMRule) = 0

struct MaxDrawbackRule <: AbstractRMRule
    switch::Bool
    drawback::Dict{String,Float64}    # 策略ID => 回撤阈值
    default_drawback::Float64          # 默认回撤阈值
    init_state::Dict{String,DrawbackState}    # 代码配置模式：直接传入历史状态
end
rmtype_id(::MaxDrawbackRule) = 2

# 便捷构造器
# 例: MaxDrawbackRule(default_drawback=-0.2, drawback=Dict("SMA"=>-0.1))
MaxDrawbackRule(; switch::Bool=true,
                  default_drawback::Real=-1.0,
                  drawback::Dict{String,Float64}=Dict{String,Float64}(),
                  init_state::Dict{String,DrawbackState}=Dict{String,DrawbackState}()) =
    MaxDrawbackRule(switch, drawback, Float64(default_drawback), init_state)

struct MaxLossRule <: AbstractRMRule
    switch::Bool
    maxloss::Dict{String,Int64}     # 策略ID => 亏损阈值（扩大万倍）
    defaultloss::Int64
end
rmtype_id(::MaxLossRule) = 3

# 便捷构造器
# 例: MaxLossRule(defaultloss=30000, maxloss=Dict("SMA"=>1000))
MaxLossRule(; switch::Bool=true,
              defaultloss::Int64=Int64(0),
              maxloss::Dict{String,Int64}=Dict{String,Int64}()) =
    MaxLossRule(switch, maxloss, Int64(defaultloss))

struct RiskRateRule <: AbstractRMRule
    switch::Bool
    maxrisk::Dict{String,Float64}     # 策略ID => 风险度阈值
    default_risk::Float64
end
rmtype_id(::RiskRateRule) = 4

# 便捷构造器
# 例: RiskRateRule(default_risk=0.9, maxrisk=Dict("SMA"=>0.8))
RiskRateRule(; switch::Bool=true,
               default_risk::Real=0.9,
               maxrisk::Dict{String,Float64}=Dict{String,Float64}()) =
    RiskRateRule(switch, maxrisk, Float64(default_risk))

struct MaxCloseRule <: AbstractRMRule
    switch::Bool
end
rmtype_id(::MaxCloseRule) = 5

# 便捷构造器：默认启用
MaxCloseRule(; switch::Bool=true) = MaxCloseRule(switch)

struct MaxCapitalRule <: AbstractRMRule
    switch::Bool
end
rmtype_id(::MaxCapitalRule) = 6

# 便捷构造器：默认启用
MaxCapitalRule(; switch::Bool=true) = MaxCapitalRule(switch)

# 频繁委托风控：策略下委托后，到收到委托/成交回报之前，禁止新委托
struct FrequentOrderRule <: AbstractRMRule
    switch::Bool
    strategyid::Set{String}    # 适用的策略ID集合，空集合表示对所有策略生效
end
rmtype_id(::FrequentOrderRule) = 1

# 便捷构造器：默认空集合（适用所有策略）
FrequentOrderRule(;switch::Bool=true) = FrequentOrderRule(switch, Set{String}())


# 风控配置结构体（用于 rm_init 的结构化入参）
mutable struct RMConfig
    account_id::String           # 账户ID
    account_type::Int            # 账户类型
    # 代码配置的风控规则
    rules::Vector{AbstractRMRule}
end

# ============================================
# 全局状态
# ============================================

const rm_rules = Vector{AbstractRMRule}()
const rm_initialized = Ref{Bool}(false)
const rm_lock = Base.Threads.ReentrantLock()

# 最大回撤状态: strategy_id -> DrawbackState
const rm_drawback_state = Dict{String, DrawbackState}()

# 已知策略列表（用于紧急风控扫描）
const rm_known_strategies = Set{String}()

# 频繁委托风控：strategy_id -> 最近一次未确认回报的 cl_order_id
const rm_pending_orders = Dict{String, String}()

# 账户标识（用于风控触发后传给执行引擎）
const rm_account_id = Ref{String}("")
const rm_account_type = Ref{Int}(0)


# ============================================
# OMS 查询接口（可插拔，支持本地库或TCP代理）
# 实际 Ref 由调用方注入，命名约定：
#   oms_query_fund / oms_query_position / oms_query_order /
#   oms_query_order_ids / oms_query_order_id_by_cl /
#   oms_query_strategy_ids
# ============================================
#const oms_query_position = Ref{Function}(OrderManager.om_query_contract_stat)
#const oms_query_fund      = Ref{Function}(OrderManager.om_query_fund)
#const oms_query_order_ids = Ref{Function}(OrderManager.om_query_order_ids)
#const oms_query_order_id_by_cl = Ref{Function}(OrderManager.om_query_order_id_by_cl_order_id)
#const oms_query_order_cl_and_strategy = Ref{Function}(OrderManager.om_query_order_cl_and_strategy)
#const oms_query_order = Ref{Function}(OrderManager.om_query_order)
#const oms_query_strategyids = Ref{Function}(OrderManager.om_query_strategy_ids)

# ============================================
# 初始化与配置解析
# ============================================

function rm_init(config::RMConfig)::Int
    lock(rm_lock) do
        try
            # 清空状态
            empty!(rm_rules)
            empty!(rm_drawback_state)
            empty!(rm_pending_orders)

            # === 配置有效性检查 ===
            if isempty(config.rules)
                strategy_log(4, "风控配置：rules不能为空")
                return -1
            end

            # 设置作用域
            rm_account_id[] = config.account_id
            rm_account_type[] = config.account_type

            # 加载风控规则
            for rule in config.rules
                push!(rm_rules, rule)
                strategy_log(2, "[RiskManagement] 加载风控规则: type=$(typeof(rule).name.name), switch=$(rule.switch)")
            end
            # 初始化最大回撤状态
            for rule in rm_rules
                if rule isa MaxDrawbackRule
                    init_drawback_state(rule)
                end
            end
            rm_initialized[] = true
            strategy_log(2, "[RiskManagement] 风控模块初始化完成，规则数=$(length(rm_rules))")
            return 0
        catch e
            strategy_log(4, "风控模块初始化异常: $e")
            return -2
        end
    end
end


function init_drawback_state(rule::MaxDrawbackRule)
    # 优先：代码配置模式，直接使用 init_state
    if !isempty(rule.init_state)
        for (strategy_id, state) in rule.init_state
            rm_drawback_state[strategy_id] = DrawbackState(
                state.history_netvalue,
                state.history_max_netvalue,
                state.history_drawback
            )
            strategy_log(2, "[RiskManagement] 最大回撤状态初始化(代码配置): strategy_id=$strategy_id, netvalue=$(state.history_netvalue), max_netvalue=$(state.history_max_netvalue), drawback=$(state.history_drawback)")
        end
    end
end

# ============================================
# check_rule 多重派发
# ============================================

# ---- FrequentOrderRule ----
# 利用 om_query_order_id_by_cl_order_id 判断回报是否已到达：
#   返回非空 order_id 表示 OMS 已记录该委托（已收到回报），可以放行新委托；
#   返回空字符串表示尚未收到回报，拒绝新委托。
function check_rule(rule::FrequentOrderRule, strategy_id::String, cl_order_id::String)::Int
    if !rule.switch
        return 0
    end
    # 策略ID过滤：strategyid 非空时，仅对指定策略生效
    if !isempty(rule.strategyid) && !(strategy_id in rule.strategyid)
        return 0
    end

    pending_cl_oid = get(rm_pending_orders, strategy_id, "")
    if isempty(pending_cl_oid)
        return 0  # 无未决委托，放行
    end

    order_id = oms_query_order_id_by_cl[](strategy_id, pending_cl_oid)
    if isempty(order_id)
        # 未收到回报，拒绝新委托
        strategy_log(2, "[RiskManagement] 频繁委托风控拦截: strategy_id=$strategy_id, pending_cl_orderid=$pending_cl_oid, new_cl_orderid=$cl_order_id")
        return RM_TYPE_FREQUENT_ORDER
    end
    # 回报已到达，删除旧记录，由 rm_order 在放行后写入新记录
    delete!(rm_pending_orders, strategy_id)
    return 0
end

# ---- MaxDrawbackRule ----
function check_rule(rule::MaxDrawbackRule, strategy_id::String)::Int
    if !rule.switch
        return 0 
    end
    threshold = get(rule.drawback, strategy_id, nothing)
    if threshold === nothing
        threshold = rule.default_drawback
    end
    if threshold === nothing
        return 0  # 未配置阈值，跳过
    end

    # 查询实时权益
    fund = oms_query_fund[](strategy_id)
    if fund === nothing
        return 0  # 查询失败，保守通过
    end
    equity = fund.equity
    start_equity = fund.start_equity
    if start_equity == 0
        return 0
    end
    # 获取或初始化状态
    if !haskey(rm_drawback_state, strategy_id)
        history_netvalue = 1.0
        history_max_netvalue = 1.0
        history_drawback = 0.0
        rm_drawback_state[strategy_id] = DrawbackState(history_netvalue, history_max_netvalue, history_drawback)
    end

    state = rm_drawback_state[strategy_id]

    # 计算当前净值
    cur_netvalue = state.history_netvalue + (equity - start_equity) / start_equity
    # 更新最大净值和回撤
    state.history_max_netvalue = max(state.history_max_netvalue, cur_netvalue)
    cur_drawback = (cur_netvalue - state.history_max_netvalue) / state.history_max_netvalue
    state.history_drawback = min(state.history_drawback, cur_drawback)

    if cur_drawback <= threshold
        strategy_log(2, "[RiskManagement] 最大回撤风控触发: strategy_id=$strategy_id, cur_drawback=$(round(cur_drawback,digits=4)), threshold=$threshold")
        return RM_TYPE_MAX_DRAWBACK
    end
    return 0
end

# ---- MaxLossRule ----
function check_rule(rule::MaxLossRule, strategy_id::String)::Int
    if !rule.switch; return 0; end
    threshold = get(rule.maxloss, strategy_id, nothing)
    if threshold === nothing
        threshold = rule.defaultloss
    end
    if threshold === nothing
        return 0
    end

    # 查询实时权益
    fund = oms_query_fund[](strategy_id)
    if fund === nothing
        return 0
    end
    start_equity = fund.start_equity
    equity = fund.equity
    loss = start_equity - equity  # 亏损金额（已扩大一万倍）

    if loss >= threshold
        strategy_log(2, "[RiskManagement] 最大亏损风控触发: strategy_id=$strategy_id, loss=$loss, threshold=$threshold")
        return RM_TYPE_MAX_LOSS
    end
    return 0
end

# ---- RiskRateRule ----
function check_rule(rule::RiskRateRule, strategy_id::String)::Int
    if !rule.switch; return 0; end
    threshold = get(rule.maxrisk, strategy_id, nothing)
    if threshold === nothing
        threshold = rule.default_risk
    end
    if threshold === nothing
        return 0
    end

    # 查询实时权益和保证金
    fund = oms_query_fund[](strategy_id)
    if fund === nothing
        return 0
    end
    equity = fund.equity
    margin = fund.margin
    if equity == 0
        return 0
    end
    risk_rate = margin / equity

    if risk_rate >= threshold
        strategy_log(2, "[RiskManagement] 风险度风控触发: strategy_id=$strategy_id, risk_rate=$(round(risk_rate,digits=4)), threshold=$threshold")
        return RM_TYPE_RISK_RATE
    end
    return 0
end

# ---- MaxCloseRule ----
function check_rule(rule::MaxCloseRule, strategy_id::String, symbol::String, side::Int16, volume::Int32, price::Int64)::Int
    if !rule.switch; return 0; end
    # 判断是否为平仓指令
    is_close = side in [SIDE_LONG_CLOSE, SIDE_SHORT_CLOSE,
                        SIDE_TODAY_LONG_CLOSE, SIDE_TODAY_SHORT_CLOSE,
                        SIDE_PREDAY_LONG_CLOSE, SIDE_PREDAY_SHORT_CLOSE]
    if !is_close
        return 0  # 非平仓指令，跳过
    end

    # 查询持仓
    pos = oms_query_position[](strategy_id, symbol)
    if pos === nothing
        strategy_log(2, "[RiskManagement] 最大平仓风控拦截(无持仓): strategy_id=$strategy_id, symbol=$symbol, side=$side, volume=$volume")
        return RM_TYPE_MAX_CLOSE
    end

    # 判断多空方向，获取可用持仓
    available = 0
    if side in [SIDE_LONG_CLOSE, SIDE_TODAY_LONG_CLOSE, SIDE_PREDAY_LONG_CLOSE]
        available = pos.today_long_volume + pos.yesterday_long_volume - pos.today_long_frozen - pos.yesterday_long_frozen
    else
        available = pos.today_short_volume + pos.yesterday_short_volume - pos.today_short_frozen - pos.yesterday_short_frozen
    end

    if available < volume
        strategy_log(2, "[RiskManagement] 最大平仓风控拦截(持仓不足): strategy_id=$strategy_id, symbol=$symbol, side=$side, volume=$volume, available=$available")
        return RM_TYPE_MAX_CLOSE
    end
    return 0
end

# ---- MaxCapitalRule ----
function check_rule(rule::MaxCapitalRule, strategy_id::String, symbol::String, side::Int16, volume::Int32, price::Int64)::Int
    if !rule.switch; return 0; end
    codeinfo = get_codeinfo(symbol)
    multiplier = codeinfo.multiplier
    # 判断是否为开仓指令
    if side == SIDE_LONG_OPEN
        margin_ratio = codeinfo.margin_ratio_param1/10000.0
    elseif side == SIDE_SHORT_OPEN
        margin_ratio = codeinfo.margin_ratio_param2/10000.0
    else
        return 0
    end
    # 查询可用资金
    fund = oms_query_fund[](strategy_id)
    if fund === nothing
        return 0
    end
    avail_cash = fund.avail_cash
    # 计算开仓资金（近似：价格 × 手数）
    open_capital = price * volume * multiplier * margin_ratio  # 扩大一万倍后的价格 × 手数
    fee = (volume*codeinfo.open_commission/10000.0 + price * volume * multiplier *codeinfo.open_commission_ratio/10000000.0)
    if avail_cash < open_capital + fee
        strategy_log(2, "[RiskManagement] 最大资金风控拦截(资金不足): strategy_id=$strategy_id, symbol=$symbol, side=$side, volume=$volume, open_capital=$open_capital, avail_cash=$avail_cash")
        return RM_TYPE_MAX_CAPITAL
    end
    return 0
end

# ============================================
# 主接口：rm_order
# ============================================

"""
    rm_order(inorders::Vector{cOrderReq}; emergency::Bool=false)::Vector{Int}

批量下单前风控检查。

入参 cl_order_id 约定为 'strategy_id,cl_order_id' 格式（逗号分隔），
内部解析后按策略走风控规则；不含逗号的 cl_order_id 视作非策略单，直接放行。

emergency=true 时只跑白名单内的规则（FrequentOrderRule + MaxCloseRule），其它一律跳过。
- FrequentOrderRule：提供时序锁，等上一笔回报到达再发下一笔，让 OMS 状态保持新鲜
- MaxCloseRule：持仓校验，依赖 FreqRule 提供的'OMS 已新鲜'前提，防止跨策略平仓
其它规则（含将来新增的）默认全部跳过——避免触发型规则（MaxDrawback/MaxLoss/RiskRate）
持续阻挡紧急清仓自身的发单。新加规则若需在紧急路径生效，请显式加入白名单。

返回：长度等于 inorders 的 Vector{Int}
  - results[i] = 0       第 i 个委托通过风控
  - results[i] = rmtype  第 i 个委托被该 rmtype 对应的风控拦截

风控未初始化时返回全 0（即放行）。
"""
function rm_order(inorders::Vector{cOrderReq}; emergency::Bool=false)::Vector{Int}
    results = zeros(Int, length(inorders))
    if !rm_initialized[]
        return results
    end
    t_lock_start = time_ns()
    lock(rm_lock) do
        for i in 1:length(inorders)
            order = inorders[i]
            cl_order_id = unsafe_string(pointer(reinterpret.(UInt8,order.cl_order_id)))
            parts = split(cl_order_id, ",")
            if length(parts) < 2
                results[i] = 0
                continue
            end
            strategy_id = string(parts[1])
            cl_order_id = string(parts[2])
            symbol = unsafe_string(pointer(reinterpret.(UInt8,order.symbol)))
            side = order.side
            volume = order.volume
            price = order.price
            if isempty(strategy_id)
                results[i] = 0
                continue
            end

            # 记录已知策略
            push!(rm_known_strategies, strategy_id)

            result = 0

            # 逐条风控规则检查（短路：一旦触发任一规则即停止）
            for rule in rm_rules
                if !rule.switch
                    continue
                end
                # 紧急模式只跑白名单内的规则；其它一律跳过
                if emergency && !(rule isa FrequentOrderRule || rule isa MaxCloseRule)
                    continue
                end
                if rule isa FrequentOrderRule
                    result = check_rule(rule, strategy_id, cl_order_id)
                elseif rule isa MaxCloseRule || rule isa MaxCapitalRule
                    result = check_rule(rule, strategy_id, symbol, side, volume, price)
                else
                    result = check_rule(rule, strategy_id)
                end
                if result != 0
                    break
                end
            end

            results[i] = result
            if result != 0
                strategy_log(2, "[RiskManagement] rm_order拦截: strategy_id=$strategy_id, symbol=$symbol, side=$side, volume=$volume, 风控类型=$result")
            else
                # 放行：若启用了频繁委托风控，记录最近一次未确认回报的 cl_order_id
                for rule in rm_rules
                    if rule isa FrequentOrderRule && rule.switch
                        if isempty(rule.strategyid) || strategy_id in rule.strategyid
                            rm_pending_orders[strategy_id] = cl_order_id
                        end
                        break
                    end
                end
            end
        end
    end
    elapsed_ms = (time_ns() - t_lock_start) ÷ 1_000_000
    if elapsed_ms > RM_LOCK_WARN_MS
        strategy_log(3, "[RiskManagement] rm_order 持锁/等待 $(elapsed_ms)ms 超过阈值 $(RM_LOCK_WARN_MS)ms, 订单数=$(length(inorders))")
    end
    return results
end

"""
    rm_unregister_pending(strategy_id::String, cl_order_id::String)

回滚 FrequentOrderRule 对该 strategy_id 的"已发出"登记。
用于 td_order 失败 / 异常时由调用方调用——rm_order 在风控通过的瞬间就把
rm_pending_orders[strategy_id] 写为 cl_order_id，但若后续真正的发单步骤失败，
这条 cl_order_id 永远不会到达 OMS、永远拿不到回报，FrequentOrderRule 会永久卡死该策略。

仅当当前 pending 与传入的 cl_order_id 完全一致时才删除——防止并发场景下误删后续合法记录。
"""
function rm_unregister_pending(strategy_id::String, cl_order_id::String)
    lock(rm_lock) do
        if get(rm_pending_orders, strategy_id, "") == cl_order_id
            delete!(rm_pending_orders, strategy_id)
        end
    end
end

"""
    rm_on_trading_day_change()

日切处理：清空 rm_pending_orders。

OMS 在跨交易日时会重置当日委托记录，但 rm_pending_orders 是进程级 in-memory 状态，
不随 OMS 同步清理。若上一交易日末尾的 cl_order_id 跨入新一日，oms_query_order_id_by_cl
查询会因记录已轮转而返回空字符串，导致 FrequentOrderRule 误判为"上一笔未收回报"
而拦截当日新委托。日切时主动清空可消除此误拦截。
"""
function rm_on_trading_day_change()
    lock(rm_lock) do
        if !isempty(rm_pending_orders)
            strategy_log(2, "[RiskManagement] 日切清空 rm_pending_orders, count=$(length(rm_pending_orders))")
            empty!(rm_pending_orders)
        end
    end
end

# ============================================
# 主接口：rm_price
# ============================================

"""
    rm_price(trade_date::Integer, code::String, ask_price::Integer, bid_price::Integer, match_price::Integer)

行情快照驱动的策略级紧急风控（最大回撤 / 当日最大亏损 / 风险度）。

入参：
  - trade_date：交易日 YYYYMMDD
  - code：合约代码
  - ask_price / bid_price：当前买一/卖一价（×10000 后的整数）
  - match_price：当前最新价（×10000 后的整数）

行为：
  对每个已知策略逐条扫描启用的 2/3/4 类规则；命中后调用 create_risk_close_task
  在执行引擎中创建该 (strategy_id, code) 的清仓任务，由执行引擎负责撤单和平仓。
  本函数本身不直接产生 OrderReq。

⚠ 已知局限：触发的是策略级权益指标，但本次只清掉行情所属的 code，
  不清同策略下其它合约的持仓。原因是 rm_price 仅携带单 code 的最新价，
  无法立即对其它持仓合约挂出合理的限价单。
  对跨品种策略，需依赖每个合约自身的行情快照分别触发清仓——
  即同一策略的风控触发可能跨多帧行情才完成全部清仓。

返回：nothing
"""
function rm_price(trade_date::Integer, code::String, ask_price::Integer, bid_price::Integer, match_price::Integer)
    if !rm_initialized[]
        return nothing
    end
    trade_date = Int(trade_date)
    ask_price = Int64(ask_price)
    bid_price = Int64(bid_price)
    match_price = Int64(match_price)
    t_lock_start = time_ns()
    lock(rm_lock) do
        # ---- 2/3/4 类紧急风控：回撤、亏损、风险度 ----
        external_ids = try
            oms_query_strategy_ids[]()
        catch e
            strategy_log(3, "[RiskManagement] 查询策略列表异常: $e")
            String[]
        end
        external_ids = union(rm_known_strategies, external_ids)
        all_strategy_ids = Vector{String}()
        # 触发的策略 → 首次命中的规则名（同策略多规则触发时只记录第一次，避免日志失真）
        for strategy_id in all_strategy_ids
            if code in oms_query_position_codes(strategy_id, 2, 2, 2)
                push!(all_strategy_ids, strategy_id)
            end
        end
        close_strategies = Dict{String, String}()
        for rule in rm_rules
            if !rule.switch
                continue
            end
            if rule isa MaxDrawbackRule || rule isa MaxLossRule || rule isa RiskRateRule
                rule_name = string(typeof(rule).name.name)
                for strategy_id in all_strategy_ids
                    result = check_rule(rule, strategy_id)
                    if result != 0 && !haskey(close_strategies, strategy_id)
                        close_strategies[strategy_id] = rule_name
                    end
                end
            end
        end
        for (strategy_id, rule_name) in close_strategies
            try
                task_id = create_risk_close_task(
                    trade_date, code, bid_price, ask_price,
                    rm_account_id[], rm_account_type[], strategy_id)
                strategy_log(2, "[RiskManagement] 风控触发清仓任务: strategy_id=$strategy_id, code=$code, rule=$rule_name, task_id=$task_id")
            catch e
                strategy_log(4, "[RiskManagement] 创建风控清仓任务异常: strategy_id=$strategy_id, code=$code, error=$e")
            end
        end
    end
    elapsed_ms = (time_ns() - t_lock_start) ÷ 1_000_000
    if elapsed_ms > RM_LOCK_WARN_MS
        strategy_log(3, "[RiskManagement] rm_price 持锁/等待 $(elapsed_ms)ms 超过阈值 $(RM_LOCK_WARN_MS)ms, code=$code")
    end
    return nothing
end

