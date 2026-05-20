# 期货交易执行引擎 V2
# 基于 OMS 查询驱动的执行引擎，不再自行跟踪订单状态
# 核心理念：通过查询 OrderManager Service (OMS) 来决策，而非维护本地状态
#
# 状态机设计：5 个非终态 + 评估循环 + 2 个终态
#   :evaluating → 查询 OMS，决策下一步
#     → 发现反向未成交委托 → 发送撤单 → :canceling
#     → 发现反向持仓     → 发送平仓单 → :closing
#     → 无障碍，需补量    → 发送开仓单 → :opening
#     → 目标已达成且挂载 TP/SL → :armed
#     → 目标已达成无 TP/SL    → :completed
#     → 前置条件不满足         → :failed
#   :canceling → 等待撤单结果 → :evaluating
#   :closing   → 等待平仓成交 → :evaluating
#   :opening   → 等待开仓成交 → :evaluating（再判断 :completed/:armed）
#   :armed     → 等待行情触发 TP/SL（仅由 price_notify! 唤醒，不受 evaluate!/超时驱动）
#                价格触发 → :evaluating（走 evaluate_for_tpst_action!）
#   :completed / :failed → 终态，finalize_task! 清理

# ============================================
# 1. 数据结构和常量
# ============================================

# 订单状态常量（用于 OMS 查询结果判断）
const ORDER_STATUS_PENDING_NEW = Int16(1)
const ORDER_STATUS_NEW = Int16(2)
const ORDER_STATUS_PARTIALLY_FILLED = Int16(3)
const ORDER_STATUS_FILLED = Int16(4)
const ORDER_STATUS_PENDING_CANCEL = Int16(5)
const ORDER_STATUS_CANCELING = Int16(6)
const ORDER_STATUS_CANCEL_FILLED = Int16(7)
const ORDER_STATUS_PARTIALLY_CANCELED = Int16(8)
const ORDER_STATUS_REJECTED = Int16(9)

# 方向常量
const SIDE_LONG_OPEN = Int16(3)           # 多开
const SIDE_LONG_CLOSE = Int16(4)          # 多平
const SIDE_SHORT_OPEN = Int16(5)          # 空开
const SIDE_SHORT_CLOSE = Int16(6)         # 空平
const SIDE_TODAY_LONG_CLOSE = Int16(8)    # 多平今
const SIDE_TODAY_SHORT_CLOSE = Int16(10)  # 空平今
const SIDE_PREDAY_LONG_CLOSE = Int16(11)  # 多平昨
const SIDE_PREDAY_SHORT_CLOSE = Int16(12) # 空平昨

# 活跃订单状态集合（非终态）
const ACTIVE_ORDER_STATUSES = Set{Int16}([
    ORDER_STATUS_PENDING_NEW,
    ORDER_STATUS_NEW,
    ORDER_STATUS_PARTIALLY_FILLED,
    ORDER_STATUS_PENDING_CANCEL,
    ORDER_STATUS_CANCELING
])

# 止盈止损规格（任务可选挂载）
# 任务建仓完成后挂载一份 TPSTSpec → 进入 :armed 状态等待价格触发
# 触发后的动作由 task.task_type 决定：
#   :normal → 平掉 tpst.side 方向持仓
#   :locked → 开 tpst.side 反方向（对冲锁仓）
mutable struct TPSTSpec
    condition::Char         # '1'/'2' 移动止损; '5'-'H' 条件价
    price::Int64            # 移动止损绝对值/比例(×10000); 条件单的触发价(×10000)
    volume::Int32           # -1 = 触发后按任务规模处理；0<v<=task.volume 部分处理；v>task.volume 等同 -1
    triggered::Bool         # false=待触发; true=已触发，evaluate! 走 action 分支
    trigger_price::Int64    # 移动止损动态止损线（条件单忽略，直接对比 price）
    entry_price::Int64      # :armed 入场时记录（取自任务目标价 bid/ask）
    side::Int16             # 入场方向：SIDE_LONG_OPEN / SIDE_SHORT_OPEN
    tpst_cl_order_ids::Vector{String}  # TP/SL 触发后，本任务发出的所有动作订单 cl_order_id（:normal 平仓 / :locked 平昨同向 + 反向对冲开仓 共用一份；按净敞口减少量等效累计）
end

# 便捷构造器：仅暴露用户语义字段（condition/price/volume），
# 运行态字段（triggered/trigger_price/entry_price/side/tpst_cl_order_ids）由引擎内部填充。
# 例: TPSTSpec(condition='1', price=100, volume=-1)
TPSTSpec(; condition::Char,
           price::Integer,
           volume::Integer=-1) =
    TPSTSpec(condition, Int64(price), Int32(volume),
             false, Int64(0), Int64(0), Int16(0), String[])

# 执行任务结构体
mutable struct ExecutionTask
    trade_date::Int       # 交易日期(YYYYMMDD)
    task_id::String
    task_type::Symbol      # :normal 普通任务; :locked 锁仓任务; :risk_close 风控清仓任务（不可被新普通任务替换）
    account_id::String
    account_type::Int
    symbol::String
    target_side::String      # "long" / "short"
    volume::Int
    bid_price::Int64             # 目标价格（扩大万倍）
    ask_price::Int64             # 目标价格（扩大万倍）
    strategy_id::String
    
    phase::Symbol            # :evaluating, :canceling, :closing, :opening, :armed, :completed, :failed

    last_sent_cl_order_id::String           # 最近发出的 cl_order_id（防重复发单）
    last_cancel_target_ids::Vector{String}  # 最近撤单的目标 order_ids

    last_action_time::Int64  # 最后动作时间（毫秒时间戳）
    retry_count::Int
    max_retries::Int
    timeout_ms::Int64

    create_time::Int64
    error_msg::String

    tpst::Union{TPSTSpec,Nothing}   # 可选止盈止损：nothing 表示无 TP/SL，行为与原状一致
end

# 全局状态
const exec_active_tasks = Dict{String, ExecutionTask}()   # task_id -> ExecutionTask
const exec_symbol_tasks = Dict{Tuple{String,String}, String}()  # (strategy_id, symbol) -> task_id
const order_counter = Base.Threads.Atomic{Int}(0)

#OrderManager依赖
#oms_query_order
#oms_query_position

# ============================================
# 2. 工具函数
# ============================================
# 字符串转 Carray，用于填充 C 语言结构体
function str_to_carray_memcpy(s::String, ::Val{N}) where N
    ref = Libc.malloc(Carray{Int8, N}())
    GC.@preserve s ref begin
        len = min(ncodeunits(s), N)
        unsafe_copyto!(
            Ptr{UInt8}(Base.unsafe_convert(Ptr{Carray{Int8, N}}, ref)),
            pointer(s),
            len
        )
    end
    return ref[]
end

# 当前时间毫秒数
function now_ms()::Int64
    return time_ns() ÷ 1_000_000
end

# 生成任务ID
function gen_task_id()::String
    date_part = Dates.format(now(), "mmdd")
    seq = Base.Threads.atomic_add!(order_counter, 1) % 1000000
    return "$(date_part)$(seq)"
end

# 生成 cl_order_id
function gen_cl_order_id(task_id::String)::String
    seq = Base.Threads.atomic_add!(order_counter, 1) % 1000000
    return "$(task_id)_$(seq)"
end

# 获取交易所代码
function get_exchange(symbol::String)::String
    parts = split(symbol, ".")
    if length(parts) >= 2
        return parts[1]
    end
    return ""
end

# 判断是否为上期所或能源交易所（需要平今/平昨处理）
function is_shfe_or_ine(symbol::String)::Bool
    exchange = get_exchange(symbol)
    return exchange in ["SHFE", "INE"]
end


# ============================================
# 3. OMS 查询辅助函数
# ============================================
# 查询订单是否已终态
function is_order_final(order_id::String, oper_date::Integer, strategy_id::String)::Bool
    global oms_query_order
    try
        order = oms_query_order[](order_id, oper_date, strategy_id)
        if order === nothing
            return true  # 订单不存在，视为终态
        end
        return !(order.status in ACTIVE_ORDER_STATUSES)
    catch e
        strategy_log(4, "[ExecutionEngineV2] 查询订单状态异常: order_id=$order_id, error=$e")
        return false  # 查询失败，保守返回非终态
    end
end

# 检查所有目标订单是否都已终态
function are_all_orders_final(order_ids::Vector{String}, oper_date::Integer, strategy_id::String)::Bool
    for order_id in order_ids
        if !is_order_final(order_id, oper_date, strategy_id)
            return false
        end
    end
    return true
end

# ============================================
# 4. 核心状态检查函数
# ============================================

"""
    check_phase_status!(task::ExecutionTask)

检查当前阶段的完成情况，在 evaluate! 开头调用。
- :canceling → 查 OMS 看撤单目标是否已终态，是则切 :evaluating
- :closing → 查 OMS 看平仓单是否已成交，是则切 :evaluating  
- :opening → 查 OMS 看开仓单是否已成交，是则切 :completed
"""
function check_phase_status!(task::ExecutionTask)
    oper_date = task.trade_date
    now = now_ms()
    elapsed = now - task.last_action_time
    
    if task.phase == :canceling
        # 检查撤单目标是否都已终态
        if !isempty(task.last_cancel_target_ids)
            if are_all_orders_final(task.last_cancel_target_ids, oper_date, task.strategy_id)
                strategy_log(2, "[ExecutionEngineV2] 撤单完成，切回评估阶段: task=$(task.task_id)")
                task.phase = :evaluating
                task.retry_count = 0
                return true
            end
        else
            # 没有撤单目标，直接切回评估
            task.phase = :evaluating
            return true
        end
        
        # 检查超时
        if elapsed > task.timeout_ms
            strategy_log(3, "[ExecutionEngineV2] 撤单阶段超时: task=$(task.task_id), elapsed=$elapsed")
            task.retry_count += 1
            if task.retry_count >= task.max_retries
                task.phase = :failed
                task.error_msg = "撤单阶段超时"
            else
                # 超时后重新评估
                task.phase = :evaluating
            end
            return true
        end
        
    elseif task.phase == :closing
        # 检查平仓单是否已终态（全成或已撤）
        task.phase = :evaluating
        return true
#        if !isempty(task.last_sent_cl_order_id)
#            # 通过 OMS 查询该委托的状态
#            # 注意：这里需要查询最近发出的订单，但 OMS 查询需要 order_id
#            # 我们记录的是 cl_order_id，需要通过其他方式获取 order_id
#            # 简化处理：进入 :closing 后下次 evaluate 会重新查询
#            if elapsed > task.timeout_ms
#                strategy_log(3, "[ExecutionEngineV2] 平仓阶段超时，重新评估: task=$(task.task_id)")
#                task.phase = :evaluating
#                return true
#            end
#        else
#            task.phase = :evaluating
#            return true
#        end
        
    elseif task.phase == :opening
        # 检查开仓单是否已全成
        task.phase = :evaluating
        return true
#        if elapsed > task.timeout_ms
#            strategy_log(3, "[ExecutionEngineV2] 开仓阶段超时，重新评估: task=$(task.task_id)")
#            task.phase = :evaluating
#            return true
#        end
    end
    
    return false
end

# ============================================
# 5. 发单/撤单函数
# ============================================

"""
    send_order!(task::ExecutionTask, symbol::String, action::Symbol, direction::String, override_volume::Integer)::Bool

统一发单函数，支持开仓与各类平仓。

参数:
- task: 执行任务（用于取 strategy_id / account / 价格 / cl_order_id 计数等）
- symbol: 合约代码
- action: 订单类型
  - :open          → 开仓（用 ask_price 买 / bid_price 卖）
  - :close         → 普通平仓（非 SHFE/INE 用）
  - :preday_close  → 平昨（SHFE/INE）
  - :today_close   → 平今（SHFE/INE）
- direction: "long" 或 "short"
  - 开仓: "long"=开多, "short"=开空
  - 平仓: "long"=平多, "short"=平空
- override_volume: 本次发单数量

价格选择规则：
- 开多 / 平空 → 买入侧 → 用 task.ask_price
- 开空 / 平多 → 卖出侧 → 用 task.bid_price

副作用：
- 成功后写入 task.last_sent_cl_order_id 与 task.last_action_time
- 风控启用时（rm_initialized[]）会先调 rm_order，被风控拦截会直接返回 false 不发单

返回: Bool, true = 发单成功
"""
function send_order!(task::ExecutionTask, symbol::String, action::Symbol, 
                     direction::String, override_volume::Integer)::Bool
    try
        local side_val::Int16
        local volume::Int32
        local order_desc::String  # 订单描述，用于日志
        if action == :open
            # ========== 开仓逻辑 ==========
            side_val = direction == "long" ? SIDE_LONG_OPEN : SIDE_SHORT_OPEN
            volume = Int32(override_volume)
            order_desc = direction == "long" ? "开多" : "开空"
            price = direction == "long" ? task.ask_price : task.bid_price
        elseif action == :close
            # ========== 平仓逻辑 ==========
            if direction == "short"
                # 平空（目标是开多）
                side_val = SIDE_SHORT_CLOSE  # 6 = 空平
                volume = Int32(override_volume)
                order_desc = "空平"
                price = task.ask_price
            else
                # 平多（目标是开空）
                side_val = SIDE_LONG_CLOSE  # 4 = 多平
                volume = Int32(override_volume)
                order_desc = "多平"
                price = task.bid_price
            end   
            if volume <= 0
                task.error_msg = "平仓量为0"
                strategy_log(4, "[ExecutionEngineV2] $(task.error_msg), task=$(task.task_id)")
                return false
            end                 
        elseif action == :preday_close
            if direction == "short"
                # 平空（目标是开多）
                side_val = SIDE_PREDAY_SHORT_CLOSE  # 12 = 空平昨
                volume = Int32(override_volume)
                order_desc = "空平昨"
                price = task.ask_price
            else
                # 平多（目标是开空）
                side_val = SIDE_PREDAY_LONG_CLOSE  # 11 = 多平昨
                volume = Int32(override_volume)
                order_desc = "多平昨"
                price = task.bid_price
            end
            if volume <= 0
                task.error_msg = "平仓量为0"
                strategy_log(4, "[ExecutionEngineV2] $(task.error_msg), task=$(task.task_id)")
                return false
            end            
        elseif action == :today_close
            if direction == "short"
                # 平空（目标是开多）
                side_val = SIDE_TODAY_SHORT_CLOSE  # 10 = 空平今
                volume = Int32(override_volume)
                order_desc = "空平今"
                price = task.ask_price
            else
                # 平多（目标是开空）
                side_val = SIDE_TODAY_LONG_CLOSE  # 8 = 多平今
                volume = Int32(override_volume)
                price = task.bid_price
                order_desc = "多平今"
            end
            
            if volume <= 0
                task.error_msg = "平仓量为0"
                strategy_log(4, "[ExecutionEngineV2] $(task.error_msg), task=$(task.task_id)")
                return false
            end
        else
            task.error_msg = "无效的 action 参数: $action"
            strategy_log(4, "[ExecutionEngineV2] $(task.error_msg), task=$(task.task_id)")
            return false
        end
        # ========== 公共部分：构造并发送订单 ==========
        cl_order_id = gen_cl_order_id(task.task_id)
        cl_order_id_carray = str_to_carray_memcpy(string(task.strategy_id,",",cl_order_id), Val(32))
        symbol_carray = str_to_carray_memcpy(symbol, Val(32))
        order = cOrderReq(
            cl_order_id = cl_order_id_carray,
            symbol = symbol_carray,
            order_type = Int16(1),      # 限价单
            side = side_val,
            volume = volume,
            price = price,
            hedge_flag = Int16(1),
        )
        orders = cOrderReq[order]
        if rm_initialized[]
            results = rm_order(orders; emergency = task.task_type == :risk_close)
            if results[1] > 0
                action_str = action == :open ? "开仓" : "平仓"
                task.error_msg = "$(action_str)风控拦截导致发单失败"
                strategy_log(4, "[ExecutionEngineV2] $(task.error_msg), task=$(task.task_id), account_id=$(task.account_id), account_type=$(task.account_type)")
                fields = fieldnames(cOrderReq)
                order_str = "OrderReq\n"
                for name in fields
                    order_str = string(order_str, name, "=", repr(getproperty(orders[1], name)),"\n")
                end
                strategy_log(4, order_str)                
                return false
            end
        end
        # 调用发单接口
        err = td_order(task.account_id, task.account_type, orders, 1)
        if err != 0
            # 发单失败：回滚 rm_order 已写入的 rm_pending_orders 登记，
            # 否则 FrequentOrderRule 会永久卡死该策略（cl_oid 没到 broker，OMS 永远查不到）
            rm_initialized[] && rm_unregister_pending(task.strategy_id, cl_order_id)
            action_str = action == :open ? "开仓" : "平仓"
            task.error_msg = "$(action_str)发单失败，错误码: $err"
            strategy_log(4, "[ExecutionEngineV2] $(task.error_msg), task=$(task.task_id), account_id=$(task.account_id), account_type=$(task.account_type)")
            fields = fieldnames(cOrderReq)
            order_str = "OrderReq\n"
            for name in fields
                order_str = string(order_str, name, "=", repr(getproperty(orders[1], name)),"\n")
            end
            strategy_log(4, order_str)
            return false
        end
        # 记录最后发出的 cl_order_id
        task.last_sent_cl_order_id = cl_order_id
        task.last_action_time = now_ms()
        action_str = action == :open ? "开仓单" : "平仓单"
        strategy_log(2, "[ExecutionEngineV2] $(action_str)已发送: task=$(task.task_id), $order_desc, vol=$volume, price=$price, cl_order_id=$cl_order_id")
        return true
    catch e
        # 异常路径同样可能在 rm_order 写入后、td_order 真正成功前抛出，需要回滚
        if @isdefined(cl_order_id) && rm_initialized[]
            rm_unregister_pending(task.strategy_id, cl_order_id)
        end
        action_str = action == :open ? "开仓" : "平仓"
        task.error_msg = "$(action_str)发单异常: $e"
        strategy_log(4, "[ExecutionEngineV2] $(task.error_msg), task=$(task.task_id)")
        return false
    end
end

"""
    exec_cancel_orders!(task::ExecutionTask, order_ids::Vector{String})

发送撤单请求。
"""
function exec_cancel_orders!(task::ExecutionTask, order_ids::Vector{String})::Bool
    try
        if isempty(order_ids)
            return true
        end
        
        # 调用撤单接口
        td_cancel_order(task.account_id, task.account_type, order_ids, true)
        
        # 记录撤单目标
        task.last_cancel_target_ids = copy(order_ids)
        task.last_action_time = now_ms()
        
        strategy_log(2, "[ExecutionEngineV2] 撤单请求已发送: task=$(task.task_id), orders=$(join(order_ids, ","))")
        return true
        
    catch e
        strategy_log(4, "[ExecutionEngineV2] 撤单异常: task=$(task.task_id), error=$e")
        return false
    end
end

# ============================================
# 6. 核心评估函数
# ============================================
function query_snapshot(strategy_id::String, symbol::String)
#    pos = OrderManager.om_query_contract_stat(strategy_id, symbol)
    open_long = OrderManager.om_query_order_ids(strategy_id, 0, symbol, 1, 1)
    open_short = OrderManager.om_query_order_ids(strategy_id, 0, symbol, 1, 0)
    close_long = OrderManager.om_query_order_ids(strategy_id, 0, symbol, 0, 1)
    close_short = OrderManager.om_query_order_ids(strategy_id, 0, symbol, 0, 0)
    return  (open_long, open_short, close_long, close_short)  
end

const oms_query_snapshot = Ref{Function}(query_snapshot)

function set_oms_query_snapshot(f::Function)
    global oms_query_snapshot
    oms_query_snapshot[] = f
end


"""
    evaluate!(task::ExecutionTask)

核心评估函数！查询 OMS 确定当前态势并决策。

步骤1: 如果 phase 不是 :evaluating，检查当前阶段的完成情况
步骤2: 当 phase == :evaluating 时执行决策循环
"""
function evaluate!(task::ExecutionTask)
    # :armed 状态：等待价格触发 TP/SL，evaluate! 不做任何动作
    if task.phase == :armed
        return
    end

    # 步骤1: 检查当前阶段状态
    if task.phase != :evaluating
        phase_changed = check_phase_status!(task)

        # 如果阶段已改变，重新评估
        if phase_changed && task.phase == :evaluating
            # 继续执行下面的评估逻辑
        elseif task.phase in [:completed, :failed]
            # 任务已结束，清理
            finalize_task!(task)
            return
        elseif task.phase != :evaluating
            # 仍在等待中，不做任何动作
            return
        end
    end

    # 步骤2: 执行决策循环
    if task.phase != :evaluating
        return
    end

    sid = task.strategy_id
    symbol = task.symbol

    # 使用 snapshot 批量查询（一次 roundtrip 获取持仓 + 4 类未终态委托）
    snap = oms_query_snapshot[](sid, symbol)
    if snap === nothing
        strategy_log(4, "[ExecutionEngineV2] OMS snapshot 查询失败, task=$(task.task_id)")
        return
    end

    pos = oms_query_position[](sid, symbol)
    pending_open_long = snap[1]
    pending_open_short = snap[2]
    pending_close_long = snap[3]
    pending_close_short = snap[4]

    # TP/SL 已触发：走 action 分支（平仓/对冲），不再走原本的开仓/锁仓逻辑
    if task.tpst !== nothing && task.tpst.triggered
        evaluate_for_tpst_action!(task, pos, pending_open_long, pending_open_short)
        return
    end

    # 根据任务类型决策
    if task.task_type == :normal
        # 根据目标方向决策
        evaluate_for_open!(task, pos, pending_open_long, pending_open_short,
                          pending_close_long, pending_close_short)
    elseif task.task_type == :locked
        evaluate_for_lock!(task, pos, pending_open_long, pending_open_short,
                          pending_close_long, pending_close_short)
    elseif task.task_type == :risk_close
        evaluate_for_risk_close!(task, pos, pending_open_long, pending_open_short,
                                 pending_close_long, pending_close_short)
    else
        task.error_msg = "无效的任务类型: $(task.task_type)"
        strategy_log(4, "[ExecutionEngineV2] $(task.error_msg), task=$(task.task_id)")
    end
end

"""
    evaluate_for_open!(task, pos, pending_open_long, pending_open_short, pending_close_long, pending_close_short)

统一的开仓评估逻辑，根据 task.target_side 自动适配多/空方向：
  a. 反向开仓委托存在？→ cancel, phase=:canceling
  b. 协作平仓委托存在？→ 等待（保持 :evaluating）
  c. 矛盾平仓委托存在？→ cancel, phase=:canceling
  d. 反向持仓 > 0？→ send_close_order, phase=:closing
  e. 检查同向持仓是否已满足目标 → 已满足则撤多余委托并完成
  f. 同向开仓委托存在？→ 价格不一致则撤单；价格一致则检查量，不足则补差额
  g. 无障碍 → send_open_order, phase=:opening
"""
function evaluate_for_open!(task::ExecutionTask, pos::Union{cContractStat,Nothing},
                            pending_open_long::Vector{String}, pending_open_short::Vector{String},
                            pending_close_long::Vector{String}, pending_close_short::Vector{String})
    symbol = task.symbol
    is_long = task.target_side == "long"
    dir_label = is_long ? "多" : "空"
    rev_label = is_long ? "空" : "多"
    dir = is_long ? "long" : "short"
    rev_dir = is_long ? "short" : "long"
    
    # 方向参数绑定
    reverse_open    = is_long ? pending_open_short : pending_open_long   # 反向开仓
    coop_close      = is_long ? pending_close_short : pending_close_long # 协作平仓
    contra_close    = is_long ? pending_close_long : pending_close_short # 矛盾平仓
    same_open       = is_long ? pending_open_long : pending_open_short   # 同向开仓
    target_price    = is_long ? task.ask_price : task.bid_price          # 目标价格
    
    if pos === nothing
        rev_yesterday_vol = 0
        rev_yesterday_frz = 0
        rev_today_vol     = 0
        rev_today_frz     = 0     
        held_volume = 0    
    else
        # 反向持仓字段（需平仓的部分）
        if is_long
            rev_yesterday_vol = pos.yesterday_short_volume
            rev_yesterday_frz = pos.yesterday_short_frozen
            rev_today_vol     = pos.today_short_volume
            rev_today_frz     = pos.today_short_frozen
        else
            rev_yesterday_vol = pos.yesterday_long_volume
            rev_yesterday_frz = pos.yesterday_long_frozen
            rev_today_vol     = pos.today_long_volume
            rev_today_frz     = pos.today_long_frozen
        end
        
        # 同向持仓字段（检查目标是否达成）
        if is_long
            held_volume = pos.today_long_volume + pos.yesterday_long_volume
        else
            held_volume = pos.today_short_volume + pos.yesterday_short_volume
        end
    end

    # ---- a. 反向开仓委托存在？ ----
    if !isempty(reverse_open)
        strategy_log(2, "[ExecutionEngineV2] 发现反向开仓委托(开$(rev_label))，执行撤单: task=$(task.task_id), orders=$(join(reverse_open, ","))")
        if exec_cancel_orders!(task, reverse_open)
            task.phase = :canceling
        else
            task.retry_count += 1
            if task.retry_count >= task.max_retries
                task.phase = :failed
                task.error_msg = "撤单请求失败"
            end
        end
        return
    end
    
    # ---- b. 协作平仓委托存在？→ 等待 ----
    if !isempty(coop_close)
        strategy_log(2, "[ExecutionEngineV2] 发现平$(rev_label)委托正在执行，等待协作完成: task=$(task.task_id)")
        return
    end
    
    # ---- c. 矛盾平仓委托存在？→ 撤单 ----
    if !isempty(contra_close)
        strategy_log(3, "[ExecutionEngineV2] 发现矛盾委托(平$(dir_label))，执行撤单: task=$(task.task_id), orders=$(join(contra_close, ","))")
        if exec_cancel_orders!(task, contra_close)
            task.phase = :canceling
        else
            task.retry_count += 1
            if task.retry_count >= task.max_retries
                task.phase = :failed
                task.error_msg = "撤单请求失败"
            end
        end
        return
    end
    
    # ---- d. 反向持仓 > 0？→ 发送平仓单 ----
    rev_available = rev_yesterday_vol + rev_today_vol - rev_today_frz - rev_yesterday_frz
    if rev_available > 0
        if is_shfe_or_ine(symbol)
            yesterday_available = rev_yesterday_vol - rev_yesterday_frz
            if yesterday_available > 0
                strategy_log(2, "[ExecutionEngineV2] 发现$(rev_label)头昨仓，发送平仓单: task=$(task.task_id), pos=$yesterday_available")
                if send_order!(task, symbol, :preday_close, rev_dir, yesterday_available)
                    task.phase = :closing
                else
                    task.retry_count += 1
                    if task.retry_count >= task.max_retries
                        task.phase = :failed
                        task.error_msg = "平仓发单失败"
                    end
                end
                return
            end
            today_available = rev_today_vol - rev_today_frz
            if today_available > 0
                strategy_log(2, "[ExecutionEngineV2] 发现$(rev_label)头今仓，发送平仓单: task=$(task.task_id), pos=$today_available")
                if send_order!(task, symbol, :today_close, rev_dir, today_available)
                    task.phase = :closing
                else
                    task.retry_count += 1
                    if task.retry_count >= task.max_retries
                        task.phase = :failed
                        task.error_msg = "平仓发单失败"
                    end
                end
                return
            end
        else
            strategy_log(2, "[ExecutionEngineV2] 发现$(rev_label)头持仓，发送平仓单: task=$(task.task_id), pos=$rev_available")
            if send_order!(task, symbol, :close, rev_dir, rev_available)
                task.phase = :closing
            else
                task.retry_count += 1
                if task.retry_count >= task.max_retries
                    task.phase = :failed
                    task.error_msg = "平仓发单失败"
                end
            end
        end
        return
    end
    
    # ---- e. 检查同向持仓是否已满足目标（防止超开） ----
    if held_volume >= task.volume
        if !isempty(same_open)
            strategy_log(2, "[ExecutionEngineV2] 持仓已满足目标，撤销多余开仓委托: task=$(task.task_id), $(dir_label)_pos=$held_volume, orders=$(join(same_open, ","))")
            exec_cancel_orders!(task, same_open)
            task.phase = :canceling
            return
        end
        # 挂载了 TP/SL → 进入 :armed 等待价格触发
        if task.tpst !== nothing
            arm_task_tpst!(task)
            return
        end
        strategy_log(2, "[ExecutionEngineV2] 目标已达成，任务完成: task=$(task.task_id), $(dir_label)_pos=$held_volume")
        task.phase = :completed
        finalize_task!(task)
        return
    end
    
    # ---- f. 同向开仓委托存在？→ 检查价格和量 ----
    if !isempty(same_open)
        oper_date = task.trade_date
        pending_volume = 0
        wait_cancel = Vector{String}()
        for oid in same_open
            order_detail = oms_query_order[](oid, oper_date, task.strategy_id)
            if order_detail === nothing
                continue
            end
            if order_detail.price != target_price
                strategy_log(2, "[ExecutionEngineV2] 同向委托价格不一致，需撤单: task=$(task.task_id), order=$oid, order_price=$(order_detail.price), target_price=$target_price")
                push!(wait_cancel, oid)
            end
            pending_volume += (order_detail.volume - order_detail.filled_volume)
        end
        
        if !isempty(wait_cancel)
            strategy_log(2, "[ExecutionEngineV2] 撤销价格不一致的同向委托: task=$(task.task_id), orders=$(join(wait_cancel, ","))")
            if exec_cancel_orders!(task, wait_cancel)
                task.phase = :canceling
            else
                task.retry_count += 1
                if task.retry_count >= task.max_retries
                    task.phase = :failed
                    task.error_msg = "撤单请求失败"
                end
            end
            return
        end
        
        need_volume = task.volume - held_volume
        if pending_volume >= need_volume
            strategy_log(2, "[ExecutionEngineV2] 同向委托价量匹配，等待成交: task=$(task.task_id), pending_vol=$pending_volume, need_vol=$need_volume")
            return
        else
            diff = need_volume - pending_volume
            strategy_log(2, "[ExecutionEngineV2] 同向委托量不足，补差额下单: task=$(task.task_id), pending_vol=$pending_volume, need_vol=$need_volume, diff=$diff")
            if send_order!(task, symbol, :open, dir, diff)
                task.phase = :opening
            else
                task.retry_count += 1
                if task.retry_count >= task.max_retries
                    task.phase = :failed
                    task.error_msg = "开仓发单失败"
                end
            end
            return
        end
    end
    
    # ---- g. 无障碍 → 发送开仓单 ----
    strategy_log(2, "[ExecutionEngineV2] 条件满足，发送开仓单: task=$(task.task_id), 开$(dir_label) vol=$(task.volume)")
    if send_order!(task, symbol, :open, dir, task.volume)
        task.phase = :opening
    else
        task.retry_count += 1
        if task.retry_count >= task.max_retries
            task.phase = :failed
            task.error_msg = "开仓发单失败"
        end
    end
end

"""
    evaluate_for_lock!(task, pos, pending_open_long, pending_open_short, pending_close_long, pending_close_short)

锁仓模式评估逻辑：通过开反向仓位调整净持仓，而非直接平仓。
净持仓 net_volume = 同向持仓 - 反向持仓（正数表示同向净多/净空）

"positive" = 与 target_side 同方向，"negative" = 与 target_side 反方向

评估步骤（优先级由高到低）：
  a. 反向开仓委托存在？→ 检查价量，不合理则撤单
  b. 同向开仓委托存在？→ 检查价量，不合理则撤单
  c. 反向平仓委托存在？→ 检查价量，不合理则撤单
  d. 同向平仓委托存在？→ 检查价量，不合理则撤单
  e. 无在途委托 → 根据 net_volume 与目标的差值决定：
     - net == target → 完成
     - net > target → 平同向昨仓 或 锁反向仓
     - net < target → 平反向昨仓 或 锁同向仓
"""
function evaluate_for_lock!(task::ExecutionTask, pos::Union{cContractStat,Nothing}, pending_open_long::Vector{String}, pending_open_short::Vector{String},
        pending_close_long::Vector{String}, pending_close_short::Vector{String})
        symbol = task.symbol        
    # ---- 方向参数绑定 ----
    # positive = 同向(与target_side一致), negative = 反向
    if task.target_side == "long"
        pending_open_positive = pending_open_long
        pending_open_negative = pending_open_short
        pending_close_positive = pending_close_long
        pending_close_negative = pending_close_short
        if pos === nothing
            today_volume_positive = Int32(0)
            today_volume_negative = Int32(0)
            yesterday_volume_positive = Int32(0)
            yesterday_volume_negative = Int32(0)
            today_frozen_positive = Int32(0)
            today_frozen_negative = Int32(0)
        else
            today_volume_positive = pos.today_long_volume
            today_volume_negative = pos.today_short_volume
            yesterday_volume_positive = pos.yesterday_long_volume
            yesterday_volume_negative = pos.yesterday_short_volume
            today_frozen_positive = pos.today_long_frozen
            today_frozen_negative = pos.today_short_frozen
        end
        open_price = task.ask_price
        close_price = task.bid_price
        opposite_side = "short"
    elseif task.target_side == "short"
        pending_open_positive = pending_open_short
        pending_open_negative = pending_open_long
        pending_close_positive = pending_close_short
        pending_close_negative = pending_close_long
        if pos === nothing
            today_volume_positive = Int32(0)
            today_volume_negative = Int32(0)
            yesterday_volume_positive = Int32(0)
            yesterday_volume_negative = Int32(0)
            today_frozen_positive = Int32(0)
            today_frozen_negative = Int32(0)
        else
            today_volume_positive = pos.today_short_volume
            today_volume_negative = pos.today_long_volume
            yesterday_volume_positive = pos.yesterday_short_volume
            yesterday_volume_negative = pos.yesterday_long_volume
            today_frozen_positive = pos.today_short_frozen
            today_frozen_negative = pos.today_long_frozen
        end
        open_price = task.bid_price
        close_price = task.ask_price
        opposite_side = "long"
    else
        task.error_msg = "Invalid target side: $(task.target_side)"
        strategy_log(4, "[ExecutionEngineV2] $(task.error_msg), task=$(task.task_id)")
        return  # 无效方向，直接返回避免后续使用未定义变量
    end
    
    # 净持仓 = 同向总持仓 - 反向总持仓
    net_volume = today_volume_positive - today_volume_negative
    net_volume = net_volume + yesterday_volume_positive - yesterday_volume_negative

    # a. 反向开仓委托存在？→ 检查价量合理性
    if !isempty(pending_open_negative)
        evaluate_for_pending_order!(task, net_volume, pending_open_negative,
            :negative_open, yesterday_volume_positive, today_frozen_negative,
                open_price, close_price)
        return
    end
    # b. 同向开仓委托存在？→ 检查价量合理性
    if !isempty(pending_open_positive)
        evaluate_for_pending_order!(task, net_volume, pending_open_positive,
            :positive_open, yesterday_volume_negative, today_frozen_positive,
                open_price, close_price)
        return
    end
    # c. 反向平仓委托存在？→ 检查价量合理性
    if !isempty(pending_close_negative)
        evaluate_for_pending_order!(task, net_volume, pending_close_negative,
            :negative_close, yesterday_volume_positive, today_frozen_negative,
                open_price, close_price)
        return
    end
    # d. 同向平仓委托存在？→ 检查价量合理性
    if !isempty(pending_close_positive)
        evaluate_for_pending_order!(task, net_volume, pending_close_positive,
            :positive_close, yesterday_volume_negative, today_frozen_positive,
                open_price, close_price)
        return
    end
    # e. 无在途委托 → 根据净持仓与目标的关系决策
    if net_volume == task.volume
        # 挂载了 TP/SL → 进入 :armed 等待价格触发
        if task.tpst !== nothing
            arm_task_tpst!(task)
            return
        end
        strategy_log(2, "[ExecutionEngineV2] 目标已达成，任务完成: task=$(task.task_id), net_vol=$net_volume, target_vol=$(task.volume)")
        task.phase = :completed
        finalize_task!(task)
        return
    elseif net_volume > task.volume
        # 净持仓超出目标 → 平同向昨仓 或 开反向锁仓
        evaluate_for_net_volume!(task, net_volume, :positive, yesterday_volume_positive,
                                opposite_side)
        return
    else  # net_volume < task.volume
        # 净持仓不足目标 → 平反向昨仓 或 开同向锁仓
        evaluate_for_net_volume!(task, net_volume, :negative, yesterday_volume_negative,
                                opposite_side)
        return
    end
end

"""
    evaluate_for_pending_order!(task, net_volume, pending_orders, side, yesterday_volume, today_frozen, open_price, close_price)

锁仓模式下，检查在途委托的价格和量是否合理。

参数说明：
- side: 委托类型标识
  - :negative_open  → 反向开仓（开反方向仓位，使净持仓向目标靠近）
  - :positive_open  → 同向开仓（开同方向仓位，使净持仓远离目标）
  - :negative_close → 反向平仓（平反方向仓位，使净持仓增大）
  - :positive_close → 同向平仓（平同方向仓位，使净持仓减小）
- yesterday_volume: 可用昨仓量（开仓类传入，平仓类内部置0）
- today_frozen: 今仓冻结量（平仓类传入，开仓类内部置0）

统一判定公式（sign/yesterday_volume/today_frozen 按 side 调整）：
  等待条件: sign*net - pending - yesterday - sign*target >= 0 && today_frozen == 0
  含义：委托全部成交后，净持仓仍然在目标的合理侧 → 等待成交
  否则：委托会导致超调 → 全部撤单

各 side 展开后的等待条件：
  negative_open:  net - pv - yv_pos >= target        (反向开仓不会使净持仓低于目标)
  positive_open:  net + pv + yv_neg <= target        (同向开仓不会使净持仓超过目标)
  negative_close: net + pv <= target && frz_neg == 0 (反向平仓不会使净持仓超过目标)
  positive_close: net - pv >= target && frz_pos == 0 (同向平仓不会使净持仓低于目标)
"""
function evaluate_for_pending_order!(task::ExecutionTask, net_volume::Integer, pending_orders::Vector{String}, side::Symbol,
        yesterday_volume::Integer, today_frozen::Integer, open_price::Integer, close_price::Integer)
    net_volume = Int32(net_volume)
    yesterday_volume = Int32(yesterday_volume)
    today_frozen = Int32(today_frozen)
    open_price = Int64(open_price)
    close_price = Int64(close_price)
    # ---- 按委托类型绑定参数 ----
    # sign: 用于统一公式的符号因子
    # price: 该类委托应使用的目标价格
    # yesterday_volume/today_frozen: 开仓类置today_frozen=0，平仓类置yesterday_volume=0
    if side == :negative_open
        price = close_price       # 反向开仓用平仓价（卖价开空/买价开多）
        side_name = "反向开仓委托"
        side_en = "pending_open_negative"
        side_name2 = "开仓委托"
        side_name3 = "超量"      # 等待时：净持仓仍超出目标
        side_name4 = "不足"      # 撤单时：净持仓会低于目标
        sign = 1
        today_frozen = 0          # 开仓不涉及冻结检查
    elseif side == :positive_open
        price = open_price        # 同向开仓用开仓价
        side_name = "同向开仓委托"
        side_en = "pending_open_positive"
        side_name2 = "开仓委托"
        side_name3 = "不足"      # 等待时：净持仓仍不足目标
        side_name4 = "超量"      # 撤单时：净持仓会超出目标
        sign = -1
        today_frozen = 0          # 开仓不涉及冻结检查
    elseif side == :negative_close
        price = open_price        # 反向平仓用开仓价
        side_name = "反向平仓委托"
        side_en = "pending_close_negative"
        side_name2 = "平仓委托"
        side_name3 = "不足"      # 等待时：净持仓仍不足目标
        side_name4 = "超量"      # 撤单时：净持仓会超出目标
        sign = -1
        yesterday_volume = 0      # 平仓不考虑昨仓替代
    elseif side == :positive_close
        price = close_price       # 同向平仓用平仓价
        side_name = "同向平仓委托"
        side_en = "pending_close_positive"
        side_name2 = "平仓委托"
        side_name3 = "超量"      # 等待时：净持仓仍超出目标
        side_name4 = "不足"      # 撤单时：净持仓会低于目标
        sign = 1
        yesterday_volume = 0      # 平仓不考虑昨仓替代
    end
    
    strategy_log(2, "[ExecutionEngineV2] $(side_name)存在，检查价格和量: task=$(task.task_id), $(side_en)=$(join(pending_orders, ","))")
    
    # ---- 价格检查：逐笔比对，收集价格不一致的委托 ----
    oper_date = task.trade_date
    pending_volume = 0
    wait_cancel = Vector{String}()
    for oid in pending_orders
        order_detail = oms_query_order[](oid, oper_date, task.strategy_id)
        if order_detail === nothing
            continue
        end
        if order_detail.price != price
            strategy_log(2, "[ExecutionEngineV2] $(side_name)价格不一致，需撤单: task=$(task.task_id), order=$oid, order_price=$(order_detail.price), target_price=$(price)")
            push!(wait_cancel, oid)
        end
        pending_volume += (order_detail.volume - order_detail.filled_volume)
    end
    
    # 存在价格不一致的委托 → 撤单后重新评估
    if !isempty(wait_cancel)
        strategy_log(2, "[ExecutionEngineV2] 撤销价格不一致的$(side_name): task=$(task.task_id), orders=$(join(wait_cancel, ","))")
        if exec_cancel_orders!(task, wait_cancel)
            task.phase = :canceling
        else
            task.retry_count += 1
            if task.retry_count >= task.max_retries
                task.phase = :failed
                task.error_msg = "撤单请求失败"
            end
        end
        return
    end
    # 在途反向开仓委托: net_volume - pending_volume - yesterday_volume_positive >= task.volume
    # 在途同向开仓委托: net_volume + pending_volume + yesterday_volume_negative <= task.volume
    # 在途反向平仓委托: (net_volume + pending_volume <= task.volume) & (today_frozen_negative == 0)
    # 在途同向平仓委托: (net_volume - pending_volume >= task.volume) & (today_frozen_positive == 0)
    if (sign*net_volume - pending_volume - yesterday_volume - sign*task.volume >= 0) && (today_frozen == 0)
        strategy_log(2, "[ExecutionEngineV2] 预期净持仓量$(side_name3)，等待$(side_name2)成交: task=$(task.task_id), pending_vol=$pending_volume, need_vol=$(task.volume)")
        return
    else
        # 委托会导致超调 → 全部撤单，下次评估重新决策
        strategy_log(2, "[ExecutionEngineV2] 预期净持仓量$(side_name4)，撤掉多余$(side_name2): task=$(task.task_id), pending_vol=$pending_volume, need_vol=$(task.volume)")
        if exec_cancel_orders!(task, pending_orders)
            task.phase = :canceling
        else
            task.retry_count += 1
            if task.retry_count >= task.max_retries
                task.phase = :failed
                task.error_msg = "撤单请求失败"
            end
        end
        return
    end
end

"""
    evaluate_for_net_volume!(task, net_volume, side, yesterday_volume, opposite_side)

锁仓模式下，无在途委托时根据净持仓与目标的差值决定下单动作。

策略优先级：
  1. 有昨仓可平 → 平昨仓（减少持仓成本，上期所/能源中心用 :preday_close）
  2. 无昨仓可平 → 开反方向仓位（锁仓）

参数说明：
- side: :positive 表示净持仓超出目标（需减少），:negative 表示净持仓不足（需增加）
- yesterday_volume: 可用于平仓的昨仓量
  - :positive → yesterday_volume_positive（平同向昨仓来减少净持仓）
  - :negative → yesterday_volume_negative（平反向昨仓来增加净持仓）
- opposite_side: 与 target_side 相反的方向字符串
"""
function evaluate_for_net_volume!(task::ExecutionTask, net_volume::Integer, side::Symbol,
        yesterday_volume::Integer, opposite_side::String)
    symbol = task.symbol
    net_volume = Int32(net_volume)
    yesterday_volume = Int32(yesterday_volume)
    if side == :positive
        # 净持仓超出目标 → 需要减少 diff 手
        diff = net_volume - task.volume
        side_name = "同向"
        close_side = task.target_side  # 平同向仓减少净持仓
        open_side = opposite_side      # 或开反向仓锁定
    elseif side == :negative
        # 净持仓不足目标 → 需要增加 diff 手
        diff = task.volume - net_volume
        side_name = "反向"
        close_side = opposite_side     # 平反向仓增加净持仓
        open_side = task.target_side   # 或开同向仓锁定
    end
    # 同向持仓过多(side == :positive)，则yesterday_volume取yesterday_volume_positive
    # 反向持仓过多(side == :negative)，则yesterday_volume取yesterday_volume_negative
    # 优先平昨仓（成本更低），平仓量不超过可用昨仓
    if yesterday_volume > 0
        diff = min(diff, yesterday_volume)
        if is_shfe_or_ine(symbol)
            action = :preday_close     # 上期所/能源中心区分平今/平昨
        else
            action = :close
        end
        strategy_log(2, "[ExecutionEngineV2] $(side_name)昨日持仓大于0，优先平昨日持仓: task=$(task.task_id), net_vol=$net_volume, target_vol=$(task.volume), close_vol=$diff")
        if send_order!(task, symbol, action, close_side, diff)
            task.phase = :closing
        else
            task.retry_count += 1
            if task.retry_count >= task.max_retries
                task.phase = :failed
                task.error_msg = "平昨发单失败"
            end
        end
        return
    else
        # 无昨仓可平 → 开反方向仓位（锁仓方式调整净持仓）
        strategy_log(2, "[ExecutionEngineV2] 昨日持仓等于0，锁$(side_name)仓: task=$(task.task_id), net_vol=$net_volume, target_vol=$(task.volume), open_vol=$diff")
        if send_order!(task, symbol, :open, open_side, diff)
            task.phase = :opening
        else
            task.retry_count += 1
            if task.retry_count >= task.max_retries
                task.phase = :failed
                task.error_msg = "开仓发单失败"
            end
        end
        return
    end
end

"""
    evaluate_for_risk_close!(task, pos, pending_open_long, pending_open_short, pending_close_long, pending_close_short)

风控清仓评估逻辑：将该 (strategy_id, symbol) 的所有持仓清空。
评估步骤（优先级由高到低）：
  1. 撤销所有未成交的开仓委托（紧急情况下不应继续开仓）
  2. 已发出的平仓委托存在 → 等待回报，不重发
  3. 平多仓（SHFE/INE 区分平今/平昨；其它交易所合并平仓）
  4. 平空仓（同上）
  5. 持仓与在途委托均为空 → 任务完成
"""
function evaluate_for_risk_close!(task::ExecutionTask, pos::Union{cContractStat,Nothing},
                                  pending_open_long::Vector{String}, pending_open_short::Vector{String},
                                  pending_close_long::Vector{String}, pending_close_short::Vector{String})
    symbol = task.symbol

    # ---- 1. 撤销所有未成交的开仓委托 ----
    if !isempty(pending_open_long)
        strategy_log(3, "[ExecutionEngineV2] 风控清仓：撤销多头开仓委托: task=$(task.task_id), orders=$(join(pending_open_long, ","))")
        if exec_cancel_orders!(task, pending_open_long)
            task.phase = :canceling
        else
            task.retry_count += 1
            if task.retry_count >= task.max_retries
                task.phase = :failed
                task.error_msg = "风控清仓撤单失败"
            end
        end
        return
    end
    if !isempty(pending_open_short)
        strategy_log(3, "[ExecutionEngineV2] 风控清仓：撤销空头开仓委托: task=$(task.task_id), orders=$(join(pending_open_short, ","))")
        if exec_cancel_orders!(task, pending_open_short)
            task.phase = :canceling
        else
            task.retry_count += 1
            if task.retry_count >= task.max_retries
                task.phase = :failed
                task.error_msg = "风控清仓撤单失败"
            end
        end
        return
    end

    # ---- 2. 已发出的平仓委托存在 → 检查价格，若不利于快速成交则撤单重报 ----
    # 平多仓应以 task.bid_price 卖出：order.price > task.bid_price 说明挂高了不易成交
    # 平空仓应以 task.ask_price 买入：order.price < task.ask_price 说明挂低了不易成交
    if !isempty(pending_close_long) || !isempty(pending_close_short)
        oper_date = task.trade_date
        wait_cancel = Vector{String}()
        for oid in pending_close_long
            order_detail = oms_query_order[](oid, oper_date, task.strategy_id)
            order_detail === nothing && continue
            if order_detail.price > task.bid_price
                strategy_log(3, "[ExecutionEngineV2] 风控清仓：平多委托价不利于快速成交，撤单重报: task=$(task.task_id), order=$oid, order_price=$(order_detail.price), bid=$(task.bid_price)")
                push!(wait_cancel, oid)
            end
        end
        for oid in pending_close_short
            order_detail = oms_query_order[](oid, oper_date, task.strategy_id)
            order_detail === nothing && continue
            if order_detail.price < task.ask_price
                strategy_log(3, "[ExecutionEngineV2] 风控清仓：平空委托价不利于快速成交，撤单重报: task=$(task.task_id), order=$oid, order_price=$(order_detail.price), ask=$(task.ask_price)")
                push!(wait_cancel, oid)
            end
        end

        if !isempty(wait_cancel)
            if exec_cancel_orders!(task, wait_cancel)
                task.phase = :canceling
            else
                task.retry_count += 1
                if task.retry_count >= task.max_retries
                    task.phase = :failed
                    task.error_msg = "风控清仓撤单失败"
                end
            end
            return
        end

        # 价格仍合理 → 等待成交
        strategy_log(2, "[ExecutionEngineV2] 风控清仓：等待已发出的平仓委托完成: task=$(task.task_id)")
        return
    end

    if pos !== nothing
        long_avail_today     = pos.today_long_volume - pos.today_long_frozen
        long_avail_yesterday = pos.yesterday_long_volume - pos.yesterday_long_frozen
        long_avail_total     = long_avail_today + long_avail_yesterday

        # ---- 3. 平多仓 ----
        if long_avail_total > 0
            if is_shfe_or_ine(symbol)
                if long_avail_yesterday > 0
                    strategy_log(3, "[ExecutionEngineV2] 风控清仓：平多头昨仓: task=$(task.task_id), vol=$long_avail_yesterday")
                    if send_order!(task, symbol, :preday_close, "long", long_avail_yesterday)
                        task.phase = :closing
                    else
                        task.retry_count += 1
                        task.retry_count >= task.max_retries && (task.phase = :failed; task.error_msg = "风控平多昨发单失败")
                    end
                    return
                end
                if long_avail_today > 0
                    strategy_log(3, "[ExecutionEngineV2] 风控清仓：平多头今仓: task=$(task.task_id), vol=$long_avail_today")
                    if send_order!(task, symbol, :today_close, "long", long_avail_today)
                        task.phase = :closing
                    else
                        task.retry_count += 1
                        task.retry_count >= task.max_retries && (task.phase = :failed; task.error_msg = "风控平多今发单失败")
                    end
                    return
                end
            else
                strategy_log(3, "[ExecutionEngineV2] 风控清仓：平多头持仓: task=$(task.task_id), vol=$long_avail_total")
                if send_order!(task, symbol, :close, "long", long_avail_total)
                    task.phase = :closing
                else
                    task.retry_count += 1
                    task.retry_count >= task.max_retries && (task.phase = :failed; task.error_msg = "风控平多发单失败")
                end
                return
            end
        end

        short_avail_today     = pos.today_short_volume - pos.today_short_frozen
        short_avail_yesterday = pos.yesterday_short_volume - pos.yesterday_short_frozen
        short_avail_total     = short_avail_today + short_avail_yesterday

        # ---- 4. 平空仓 ----
        if short_avail_total > 0
            if is_shfe_or_ine(symbol)
                if short_avail_yesterday > 0
                    strategy_log(3, "[ExecutionEngineV2] 风控清仓：平空头昨仓: task=$(task.task_id), vol=$short_avail_yesterday")
                    if send_order!(task, symbol, :preday_close, "short", short_avail_yesterday)
                        task.phase = :closing
                    else
                        task.retry_count += 1
                        task.retry_count >= task.max_retries && (task.phase = :failed; task.error_msg = "风控平空昨发单失败")
                    end
                    return
                end
                if short_avail_today > 0
                    strategy_log(3, "[ExecutionEngineV2] 风控清仓：平空头今仓: task=$(task.task_id), vol=$short_avail_today")
                    if send_order!(task, symbol, :today_close, "short", short_avail_today)
                        task.phase = :closing
                    else
                        task.retry_count += 1
                        task.retry_count >= task.max_retries && (task.phase = :failed; task.error_msg = "风控平空今发单失败")
                    end
                    return
                end
            else
                strategy_log(3, "[ExecutionEngineV2] 风控清仓：平空头持仓: task=$(task.task_id), vol=$short_avail_total")
                if send_order!(task, symbol, :close, "short", short_avail_total)
                    task.phase = :closing
                else
                    task.retry_count += 1
                    task.retry_count >= task.max_retries && (task.phase = :failed; task.error_msg = "风控平空发单失败")
                end
                return
            end
        end
    end

    # ---- 5. 持仓与在途委托均为空 → 任务完成 ----
    strategy_log(2, "[ExecutionEngineV2] 风控清仓任务完成: task=$(task.task_id), strategy=$(task.strategy_id), symbol=$(task.symbol)")
    task.phase = :completed
    finalize_task!(task)
end

# ============================================
# 6.5 止盈止损 (TP/SL) 支持
# ============================================

"""
    arm_task_tpst!(task::ExecutionTask)

任务建仓目标达成且挂载了 TP/SL 时调用：记录入场参考价/方向，初始化移动止损线，进入 :armed。
入场参考价采用任务的目标价（target_side="long" 用 ask_price，"short" 用 bid_price）。
"""
function arm_task_tpst!(task::ExecutionTask)
    spec = task.tpst
    spec === nothing && return

    is_long = task.target_side == "long"
    spec.side = is_long ? SIDE_LONG_OPEN : SIDE_SHORT_OPEN
    spec.entry_price = is_long ? task.ask_price : task.bid_price

    if spec.condition == '1'
        # 按绝对值的移动止损：多仓初始下移、空仓初始上移
        spec.trigger_price = is_long ? (spec.entry_price - spec.price) :
                                       (spec.entry_price + spec.price)
    elseif spec.condition == '2'
        # 按比例的移动止损（price 是 ratio×10000）
        ratio = Float64(spec.price) / 10000.0
        trigger_price = is_long ? (spec.entry_price * (1.0 - ratio)) :
                                       (spec.entry_price * (1.0 + ratio))
        spec.trigger_price = round(Int64, trigger_price)
    else
        # 条件单：直接对比 spec.price，trigger_price 字段未使用
        spec.trigger_price = spec.price
    end

    task.phase = :armed
    task.last_action_time = now_ms()
    strategy_log(2, "[ExecutionEngineV2] 任务进入 :armed 等待 TP/SL 触发: task=$(task.task_id), entry=$(spec.entry_price), cond=$(spec.condition), trigger=$(spec.trigger_price)")
end

"""
    check_tpst_trigger!(task::ExecutionTask, ask_price, bid_price, match_price)::Bool

检查任务的 TP/SL 触发条件。移动止损会动态更新 trigger_price；条件单不修改状态。
返回 true 表示触发。
"""
function check_tpst_trigger!(task::ExecutionTask, ask_price::Integer, bid_price::Integer, match_price::Integer)::Bool
    spec = task.tpst
    spec === nothing && return false
    spec.triggered && return true   # 已触发不重复判定

    cond = spec.condition

    # 移动止损 ('1' 绝对值, '2' 比例)
    if cond == '1' || cond == '2'
        if spec.side == SIDE_LONG_OPEN
            current = bid_price   # 多仓将在 bid 卖出
            new_trigger = cond == '1' ? (current - spec.price) :
                                        (current * (1.0 - Float64(spec.price) / 10000.0))
            new_trigger = round(Int64, new_trigger)
            spec.trigger_price = max(spec.trigger_price, new_trigger)  # 只上移
            return current <= spec.trigger_price
        else  # SIDE_SHORT_OPEN
            current = ask_price   # 空仓将在 ask 买入
            new_trigger = cond == '1' ? (current + spec.price) :
                                        (current * (1.0 + Float64(spec.price) / 10000.0))
            new_trigger = round(Int64, new_trigger)
            spec.trigger_price = min(spec.trigger_price, new_trigger)  # 只下移
            return current >= spec.trigger_price
        end
    end

    # 条件单 ('5'-'H')
    pv = spec.price
    if cond == '5'; return Int64(match_price) > pv
    elseif cond == '6'; return Int64(match_price) >= pv
    elseif cond == '7'; return Int64(match_price) < pv
    elseif cond == '8'; return Int64(match_price) <= pv
    elseif cond == '9'; return Int64(ask_price) > pv
    elseif cond == 'A'; return Int64(ask_price) >= pv
    elseif cond == 'B'; return Int64(ask_price) < pv
    elseif cond == 'C'; return Int64(ask_price) <= pv
    elseif cond == 'D'; return Int64(bid_price) > pv
    elseif cond == 'E'; return Int64(bid_price) >= pv
    elseif cond == 'F'; return Int64(bid_price) < pv
    elseif cond == 'H'; return Int64(bid_price) <= pv
    end
    return false
end

"""
    evaluate_for_tpst_action!(task, pos, pending_open_long, pending_open_short)

TP/SL 触发后的动作派发：
  - task.task_type == :locked → 对冲开仓（开 spec.side 反方向，volume = spec.volume>0 ? spec.volume : 同向持仓）
  - 其它 → 平仓 spec.side 方向持仓（SHFE/INE 区分今/昨）
完成条件：动作目标达成（持仓清空 / 对冲量到位）。
"""
function evaluate_for_tpst_action!(task::ExecutionTask, pos::Union{cContractStat,Nothing},
                                   pending_open_long::Vector{String}, pending_open_short::Vector{String})
    spec = task.tpst
    if spec === nothing
        # 不该到这里，保险起见 finalize
        task.phase = :completed
        finalize_task!(task)
        return
    end

    if task.task_type == :locked
        evaluate_for_tpst_hedge!(task, pos, pending_open_long, pending_open_short)
    elseif task.task_type == :normal
        evaluate_for_tpst_close!(task, pos, pending_open_long, pending_open_short)
    else
        # 不支持的 task_type 挂载了 TP/SL → 防止 :evaluating + triggered=true 死循环
        task.error_msg = "TP/SL 触发后无对应 action 路径: task_type=$(task.task_type)"
        strategy_log(4, "[ExecutionEngineV2] $(task.error_msg), task=$(task.task_id)")
        task.phase = :failed
        finalize_task!(task)
    end
end

# 平仓分支（适用 :normal 任务）：将 spec.side 方向持仓平掉
# 任务自治：进度只看本任务发出的 cl_order_id（spec.tpst_cl_order_ids），不依赖 OMS 持仓快照增量推断。
# 平昨 / 平今 / 普通平仓 三类对净敞口减少效果等效，filled_volume 直接累加。
# 永远不开反向仓——若可平仓位不足 target，就把可平的全部平掉后任务完成。
function evaluate_for_tpst_close!(task::ExecutionTask, pos::Union{cContractStat,Nothing},
                                  pending_open_long::Vector{String}, pending_open_short::Vector{String})
    spec = task.tpst
    symbol = task.symbol
    is_long = spec.side == SIDE_LONG_OPEN
    same_open = is_long ? pending_open_long : pending_open_short
    close_dir = is_long ? "long" : "short"
    # 价格审查阈值：
    #   is_long=true  → 卖单（平多 / 平多昨 / 平多今），挂单 > bid 不利
    #   is_long=false → 买单（平空 / 平空昨 / 平空今），挂单 < ask 不利
    audit_price = is_long ? task.bid_price : task.ask_price

    # 1. 撤掉同向尚未成交的开仓委托（建仓阶段已结束）
    if !isempty(same_open)
        strategy_log(3, "[ExecutionEngineV2] TP/SL 触发：撤销同向遗留开仓委托: task=$(task.task_id)")
        if exec_cancel_orders!(task, same_open)
            task.phase = :canceling
        else
            task.retry_count += 1
            task.retry_count >= task.max_retries && (task.phase = :failed; task.error_msg = "TP/SL 撤单失败")
        end
        return
    end

    # 2. 平仓目标量（spec.volume 已在 create_exec_task 钳制至 [1, task.volume]）
    target_to_close = Int(spec.volume)

    # 3. 遍历本任务的所有平仓单（含平昨/平今/普通平仓），按净敞口减少量等效累加
    oper_date = task.trade_date
    filled_vol = 0
    pending_vol = 0
    wait_cancel = String[]
    for cl_oid in spec.tpst_cl_order_ids
        order_id = oms_query_order_id_by_cl[](task.strategy_id, cl_oid)
        isempty(order_id) && continue
        order_detail = oms_query_order[](order_id, oper_date, task.strategy_id)
        order_detail === nothing && continue
        filled_vol += order_detail.filled_volume
        if order_detail.status in ACTIVE_ORDER_STATUSES
            unfavorable = is_long ? (order_detail.price > audit_price) :
                                    (order_detail.price < audit_price)
            if unfavorable
                push!(wait_cancel, order_id)
            else
                pending_vol += (order_detail.volume - order_detail.filled_volume)
            end
        end
    end

    # 4. 撤掉价格不利单（不利单的剩余量不计入 pending_vol）
    if !isempty(wait_cancel)
        strategy_log(3, "[ExecutionEngineV2] TP/SL 平仓委托价不利，撤单重报: task=$(task.task_id), orders=$(join(wait_cancel, ","))")
        if exec_cancel_orders!(task, wait_cancel)
            task.phase = :canceling
        else
            task.retry_count += 1
            task.retry_count >= task.max_retries && (task.phase = :failed; task.error_msg = "TP/SL 平仓重报撤单失败")
        end
        return
    end

    # 5. 进度判定：committed = 已成交 + 价格合理在途
    committed = filled_vol + pending_vol
    if committed >= target_to_close
        if committed > target_to_close
            # 不应该发生：每轮发单都按 diff = target - committed 严格控制。
            # 出现说明 OMS 状态异常或并发竞态，记录以便排查；不主动反向修正以免放大风险。
            strategy_log(4, "[ExecutionEngineV2] ⚠ TP/SL 平仓过冲（OMS 状态可能异常）: task=$(task.task_id), committed=$committed, target=$target_to_close, 差额=$(committed - target_to_close)")
        end
        if pending_vol > 0
            return  # 量已挂够，等待成交
        end
        strategy_log(2, "[ExecutionEngineV2] TP/SL 平仓任务完成: task=$(task.task_id), filled=$filled_vol, target=$target_to_close")
        task.phase = :completed
        finalize_task!(task)
        return
    end

    # 6. 计算可平仓位（frozen 已包含本任务在途平仓单的冻结量，避免重复发单）
    avail_today     = 0
    avail_yesterday = 0
    if pos !== nothing
        if is_long
            avail_today     = Int(pos.today_long_volume - pos.today_long_frozen)
            avail_yesterday = Int(pos.yesterday_long_volume - pos.yesterday_long_frozen)
        else
            avail_today     = Int(pos.today_short_volume - pos.today_short_frozen)
            avail_yesterday = Int(pos.yesterday_short_volume - pos.yesterday_short_frozen)
        end
    end
    avail_total = avail_today + avail_yesterday

    # 7. 可平仓位为 0 → 任务完成（永远不开反向仓）
    if avail_total == 0
        strategy_log(2, "[ExecutionEngineV2] TP/SL 平仓任务完成（可平仓位耗尽）: task=$(task.task_id), filled=$filled_vol, target=$target_to_close")
        task.phase = :completed
        finalize_task!(task)
        return
    end

    # 8. 补差额：SHFE/INE 优先平昨再平今；其它交易所统一 :close
    diff = target_to_close - committed

    if is_shfe_or_ine(symbol)
        if avail_yesterday > 0
            vol = min(diff, avail_yesterday)
            strategy_log(3, "[ExecutionEngineV2] TP/SL 平$(is_long ? "多" : "空")昨仓: task=$(task.task_id), vol=$vol, filled=$filled_vol, pending=$pending_vol, target=$target_to_close")
            if send_order!(task, symbol, :preday_close, close_dir, vol)
                push!(spec.tpst_cl_order_ids, task.last_sent_cl_order_id)
                task.phase = :closing
            else
                task.retry_count += 1
                task.retry_count >= task.max_retries && (task.phase = :failed; task.error_msg = "TP/SL 平昨发单失败")
            end
            return
        end
        if avail_today > 0
            vol = min(diff, avail_today)
            strategy_log(3, "[ExecutionEngineV2] TP/SL 平$(is_long ? "多" : "空")今仓: task=$(task.task_id), vol=$vol, filled=$filled_vol, pending=$pending_vol, target=$target_to_close")
            if send_order!(task, symbol, :today_close, close_dir, vol)
                push!(spec.tpst_cl_order_ids, task.last_sent_cl_order_id)
                task.phase = :closing
            else
                task.retry_count += 1
                task.retry_count >= task.max_retries && (task.phase = :failed; task.error_msg = "TP/SL 平今发单失败")
            end
            return
        end
    else
        vol = min(diff, avail_total)
        strategy_log(3, "[ExecutionEngineV2] TP/SL 平$(is_long ? "多" : "空")仓: task=$(task.task_id), vol=$vol, filled=$filled_vol, pending=$pending_vol, target=$target_to_close")
        if send_order!(task, symbol, :close, close_dir, vol)
            push!(spec.tpst_cl_order_ids, task.last_sent_cl_order_id)
            task.phase = :closing
        else
            task.retry_count += 1
            task.retry_count >= task.max_retries && (task.phase = :failed; task.error_msg = "TP/SL 平仓发单失败")
        end
        return
    end
end

# 对冲分支（适用 :locked 任务）：
# 任务自治：进度只看本任务发出的 cl_order_id（spec.tpst_cl_order_ids），不依赖 OMS 持仓快照。
# 平昨同向 与 反向开仓 对净敞口减少效果等效，filled_volume 直接累加。
# 补差额发单优先级：优先平昨同向（避开 SHFE/INE 平今高费）→ 昨仓不足时开反方向对冲。
function evaluate_for_tpst_hedge!(task::ExecutionTask, pos::Union{cContractStat,Nothing},
                                  pending_open_long::Vector{String}, pending_open_short::Vector{String})
    spec = task.tpst
    symbol = task.symbol
    is_long_held = spec.side == SIDE_LONG_OPEN
    hedge_dir = is_long_held ? "short" : "long"   # 反方向对冲开仓
    close_dir = is_long_held ? "long" : "short"   # 同向平昨方向
    same_open = is_long_held ? pending_open_long : pending_open_short
    # 价格审查阈值：
    #   is_long_held=true  → 卖单（平多 / 开空），挂单 > bid 不利
    #   is_long_held=false → 买单（平空 / 开多），挂单 < ask 不利
    audit_price = is_long_held ? task.bid_price : task.ask_price

    # 1. 撤同向尚未成交的开仓委托（建仓阶段已结束）
    if !isempty(same_open)
        strategy_log(3, "[ExecutionEngineV2] TP/SL 对冲：撤销同向遗留开仓委托: task=$(task.task_id)")
        if exec_cancel_orders!(task, same_open)
            task.phase = :canceling
        else
            task.retry_count += 1
            task.retry_count >= task.max_retries && (task.phase = :failed; task.error_msg = "TP/SL 对冲撤单失败")
        end
        return
    end

    # 2. 对冲目标量（spec.volume 已在 create_exec_task 钳制至 [1, task.volume]）
    hedge_to_add = Int(spec.volume)

    # 3. 遍历本任务的所有 TP/SL 单（含平昨与对冲开仓），按净敞口减少量等效累加
    oper_date = task.trade_date
    filled_vol = 0
    pending_vol = 0
    wait_cancel = String[]
    for cl_oid in spec.tpst_cl_order_ids
        order_id = oms_query_order_id_by_cl[](task.strategy_id, cl_oid)
        isempty(order_id) && continue
        order_detail = oms_query_order[](order_id, oper_date, task.strategy_id)
        order_detail === nothing && continue
        filled_vol += order_detail.filled_volume
        if order_detail.status in ACTIVE_ORDER_STATUSES
            unfavorable = is_long_held ? (order_detail.price > audit_price) :
                                         (order_detail.price < audit_price)
            if unfavorable
                push!(wait_cancel, order_id)
            else
                pending_vol += (order_detail.volume - order_detail.filled_volume)
            end
        end
    end

    # 4. 撤掉价格不利的单（不利单的剩余量不计入 pending_vol）
    if !isempty(wait_cancel)
        strategy_log(3, "[ExecutionEngineV2] TP/SL 委托价不利，撤单重报: task=$(task.task_id), orders=$(join(wait_cancel, ","))")
        if exec_cancel_orders!(task, wait_cancel)
            task.phase = :canceling
        else
            task.retry_count += 1
            task.retry_count >= task.max_retries && (task.phase = :failed; task.error_msg = "TP/SL 撤单失败")
        end
        return
    end

    # 5. 进度判定：committed = 已成交 + 价格合理在途
    committed = filled_vol + pending_vol
    if committed >= hedge_to_add
        if committed > hedge_to_add
            # 不应该发生：每轮发单量都按 diff = hedge_to_add - committed 严格控制。
            # 出现说明 OMS 状态异常或并发竞态，记录以便排查；任务仍按完成处理（不主动反向修正以免放大风险）。
            strategy_log(3, "[ExecutionEngineV2] ⚠ TP/SL 过冲（OMS 状态可能异常）: task=$(task.task_id), committed=$committed, target=$hedge_to_add, 差额=$(committed - hedge_to_add)")
        end
        if pending_vol > 0
            return  # 量已挂够，等待成交
        end
        strategy_log(2, "[ExecutionEngineV2] TP/SL 对冲任务完成: task=$(task.task_id), filled=$filled_vol, target=$hedge_to_add")
        task.phase = :completed
        finalize_task!(task)
        return
    end

    diff = hedge_to_add - committed

    # 6a. 优先平昨同向：可平昨量 = yesterday_volume - yesterday_frozen
    #     yesterday_frozen 已包含本任务在途平昨单冻结的部分，不会重复计算。
    avail_yesterday = if pos !== nothing
        is_long_held ? Int(pos.yesterday_long_volume - pos.yesterday_long_frozen) :
                       Int(pos.yesterday_short_volume - pos.yesterday_short_frozen)
    else
        0
    end

    if avail_yesterday > 0
        close_diff = min(diff, avail_yesterday)
        action = is_shfe_or_ine(symbol) ? :preday_close : :close
        strategy_log(3, "[ExecutionEngineV2] TP/SL 优先平昨: task=$(task.task_id), dir=$close_dir, vol=$close_diff, filled=$filled_vol, pending=$pending_vol, target=$hedge_to_add")
        if send_order!(task, symbol, action, close_dir, close_diff)
            push!(spec.tpst_cl_order_ids, task.last_sent_cl_order_id)
            task.phase = :closing
        else
            task.retry_count += 1
            task.retry_count >= task.max_retries && (task.phase = :failed; task.error_msg = "TP/SL 平昨发单失败")
        end
        return
    end

    # 6b. 昨仓不足，开反方向对冲补差额
    strategy_log(3, "[ExecutionEngineV2] TP/SL 对冲开仓: task=$(task.task_id), dir=$hedge_dir, vol=$diff, filled=$filled_vol, pending=$pending_vol, target=$hedge_to_add")
    if send_order!(task, symbol, :open, hedge_dir, diff)
        push!(spec.tpst_cl_order_ids, task.last_sent_cl_order_id)
        task.phase = :opening
    else
        task.retry_count += 1
        task.retry_count >= task.max_retries && (task.phase = :failed; task.error_msg = "TP/SL 对冲发单失败")
    end
end

"""
    price_notify!(symbol::String, ask_price, bid_price, match_price)

行情快照入口：扫描 :armed 状态的任务，检查 TP/SL 触发条件，触发后切回 :evaluating 推进。
该函数是 TP/SL 的唯一驱动入口，由行情快照处理器与 rm_price 并列调用。
"""
function price_notify!(symbol::String, ask_price::Integer, bid_price::Integer, match_price::Integer)
    ask_price = Int64(ask_price)
    bid_price = Int64(bid_price)
    match_price = Int64(match_price)
    triggered_tasks = String[]
    for ((sid, sym), tid) in exec_symbol_tasks
        sym == symbol || continue
        haskey(exec_active_tasks, tid) || continue
        task = exec_active_tasks[tid]
        (task.phase == :armed && task.tpst !== nothing) || continue

        if check_tpst_trigger!(task, ask_price, bid_price, match_price)
            task.tpst.triggered = true
            task.phase = :evaluating
            task.last_action_time = now_ms()
            strategy_log(3, "[ExecutionEngineV2] TP/SL 触发: task=$(task.task_id), strategy=$sid, symbol=$sym, cond=$(task.tpst.condition)")
            push!(triggered_tasks, tid)
        end
    end
    # 触发后再 evaluate（避免遍历过程中字典被修改）
    for tid in triggered_tasks
        haskey(exec_active_tasks, tid) || continue
        evaluate!(exec_active_tasks[tid])
    end
end

# ============================================
# 7. 任务生命周期管理
# ============================================
"""
    finalize_task!(task::ExecutionTask)

完成任务，清理全局状态。
"""
function finalize_task!(task::ExecutionTask)
    # 清理 (strategy_id, symbol) -> task_id 映射
    key = (task.strategy_id, task.symbol)
    if haskey(exec_symbol_tasks, key)
        if exec_symbol_tasks[key] == task.task_id
            delete!(exec_symbol_tasks, key)
        end
    end
    
    # 从活跃任务中移除
    delete!(exec_active_tasks, task.task_id)
    
    if task.phase == :completed
        strategy_log(2, "[ExecutionEngineV2] 任务完成: task=$(task.task_id), symbol=$(task.symbol)")
    else
        strategy_log(4, "[ExecutionEngineV2] 任务失败: task=$(task.task_id), symbol=$(task.symbol), error=$(task.error_msg)")
    end
end

function query_pending_orders(strategy_id::String, symbol::String, side::Integer, bs::Integer)::Vector{String}
    order_ids_str = OrderManager.om_query_order_ids(strategy_id, 0, symbol, side, bs)
    if isempty(order_ids_str)
        return String[]
    end
    # 解析逗号分隔的字符串
    order_ids = split(order_ids_str, ",")
    # 过滤空字符串
    return filter(!isempty, order_ids)
end

const oms_query_pending_orders = Ref{Function}(query_pending_orders)

function set_oms_query_pending_orders(f::Function)
    global oms_query_pending_orders
    oms_query_pending_orders[] = f
end


"""
    force_cancel_task!(task::ExecutionTask)::Vector{String}

强制取消任务（被新任务替换时调用）。
返回被撤单的 order_id 列表，供新任务接管。
"""
function force_cancel_task!(task::ExecutionTask)::Vector{String}
    strategy_log(2, "[ExecutionEngineV2] 强制取消任务: task=$(task.task_id), phase=$(task.phase), symbol=$(task.symbol)")
    
    sid = task.strategy_id
    symbol = task.symbol
    canceled_ids = String[]
    
    try
        # 查询所有未终态委托
        all_pending = oms_query_pending_orders[](sid, symbol, 3, 3)
        
        if !isempty(all_pending)
            strategy_log(2, "[ExecutionEngineV2] 撤销旧任务的未终态委托: task=$(task.task_id), orders=$(join(all_pending, ","))")
            td_cancel_order(task.account_id, task.account_type, all_pending, true)
            canceled_ids = all_pending
        end
    catch e
        strategy_log(3, "[ExecutionEngineV2] 旧任务撤单请求异常: task=$(task.task_id), error=$e")
    end
    
    # 标记为失败
    task.phase = :failed
    task.error_msg = "被新任务替换"
    
    # 清理全局状态
    delete!(exec_active_tasks, task.task_id)
    
    strategy_log(2, "[ExecutionEngineV2] 旧任务已清理: task=$(task.task_id)")
    return canceled_ids
end

# ============================================
# 8. 对外接口
# ============================================

"""
    engine_notify!(symbol::String)

行情/订单回报通知入口。
查找该 symbol 的活跃任务，如果任务在 :canceling/:closing/:opening 阶段，切换到 :evaluating 并调用 evaluate!。
"""
# 兼容版本：遍历所有策略的任务（单参数，用于调用方无法获取 strategy_id 的场景）
function engine_notify!(symbol::String)
    task_ids_to_evaluate = String[]
    for ((sid, sym), tid) in exec_symbol_tasks
        if sym == symbol
            push!(task_ids_to_evaluate, tid)
        end
    end
    for tid in task_ids_to_evaluate
        if haskey(exec_active_tasks, tid)
            task = exec_active_tasks[tid]
            if task.phase in [:canceling, :closing, :opening]
                strategy_log(2, "[ExecutionEngineV2] 收到通知，切回评估阶段: task=$(task.task_id), phase=$(task.phase)")
                task.phase = :evaluating
            end
            evaluate!(task)
        end
    end
end

# 精确版本：直接按 (strategy_id, symbol) 查找（双参数，O(1) 查询）
function engine_notify!(strategy_id::String, symbol::String)
    key = (strategy_id, symbol)
    if !haskey(exec_symbol_tasks, key)
        return
    end
    task_id = exec_symbol_tasks[key]
    if !haskey(exec_active_tasks, task_id)
        delete!(exec_symbol_tasks, key)
        return
    end
    task = exec_active_tasks[task_id]
    if task.phase in [:canceling, :closing, :opening]
        strategy_log(2, "[ExecutionEngineV2] 收到通知，切回评估阶段: task=$(task.task_id), phase=$(task.phase)")
        task.phase = :evaluating
    end
    evaluate!(task)
end

"""
    create_exec_task(symbol, target_side, volume, price, strategy_id)

创建新的执行任务。
检查 exec_symbol_tasks 互斥，如果已有同策略同合约的任务则 force_cancel_task! 旧任务。
"""
function create_exec_task(trade_date::Integer, symbol::String,
                          target_side::String, volume::Integer, bid_price::Integer,
                          ask_price::Integer, account_id::String, account_type::Integer,
                          strategy_id::String;
                          tpst::Union{TPSTSpec,Nothing}=nothing)::String
    trade_date = Int(trade_date)
    volume = Int(volume)
    bid_price = Int64(bid_price)
    ask_price = Int64(ask_price)
    account_type = Int(account_type)
    # tpst.volume 归一化（一次钳制，evaluate 每轮直接用 spec.volume）：
    #   == 0           → 未挂载 TP/SL（等同 nothing）
    #   == -1 或 > vol → 钳制到 task.volume
    #   0 < v <= vol   → 保留
    if tpst !== nothing
        if tpst.volume == 0
            strategy_log(2, "[ExecutionEngineV2] tpst.volume=0，按未挂载 TP/SL 处理: strategy_id=$strategy_id, symbol=$symbol")
            tpst = nothing
        elseif tpst.volume == -1 || Int(tpst.volume) > volume
            tpst.volume = Int32(volume)
        end
    end
    # 检查参数有效性
    if !(target_side in ["long", "short"])
        strategy_log(4, "[ExecutionEngineV2] 无效的目标方向: $target_side")
        return ""
    end
    
    if volume <= 0
        strategy_log(4, "[ExecutionEngineV2] 无效的交易量: $volume")
        return ""
    end
    
    # 获取旧任务的待撤委托（用于委托移交机制）
    canceled_ids = String[]
    
    # 检查是否已有同策略同合约的活跃任务
    key = (strategy_id, symbol)
    if haskey(exec_symbol_tasks, key)
        existing_task_id = exec_symbol_tasks[key]
        if haskey(exec_active_tasks, existing_task_id)
            old_task = exec_active_tasks[existing_task_id]
            # 风控清仓任务不可被新普通任务替换
            if old_task.task_type == :risk_close
                strategy_log(3, "[ExecutionEngineV2] 拒绝创建普通任务：风控清仓任务正在执行: strategy_id=$strategy_id, symbol=$symbol, risk_task=$existing_task_id, phase=$(old_task.phase)")
                return ""
            end
            strategy_log(2, "[ExecutionEngineV2] 策略合约已有活跃任务，执行替换: strategy_id=$strategy_id, symbol=$symbol, old_task=$existing_task_id, old_side=$(old_task.target_side), new_side=$target_side")
            canceled_ids = force_cancel_task!(old_task)
        end
        # 清理残留的映射
        delete!(exec_symbol_tasks, key)
    end
    
    # 根据是否有待撤委托决定初始状态
    initial_phase = isempty(canceled_ids) ? :evaluating : :canceling
    codeinfo = get_codeinfo(symbol)
    openlock = (codeinfo.open_commission + codeinfo.open_commission_ratio)*2
    closelock = (codeinfo.close_pre_commission + codeinfo.close_pre_commission_ratio)*2
    opentoday = codeinfo.open_commission + codeinfo.open_commission_ratio
    closetoday = codeinfo.close_today_commission + codeinfo.close_today_commission_ratio
    if openlock + closelock < opentoday + closetoday
        task_type = :locked
        strategy_log(2, "[ExecutionEngineV2] 使用锁仓方式: symbol=$symbol, openlock=$openlock, closelock=$closelock, opentoday=$opentoday, closetoday=$closetoday")
    else
        task_type = :normal
        strategy_log(2, "[ExecutionEngineV2] 使用今日开平方式: symbol=$symbol, openlock=$openlock, closelock=$closelock, opentoday=$opentoday, closetoday=$closetoday")
    end
    # 创建新任务
    now = now_ms()
    task_id = gen_task_id()
    
    task = ExecutionTask(
        trade_date,
        task_id,
        task_type,
        account_id,
        account_type,
        symbol,
        target_side,
        volume,
        bid_price,
        ask_price,
        strategy_id,
        initial_phase,         # phase: 有待撤委托时为 :canceling
        "",                    # last_sent_cl_order_id
        canceled_ids,          # last_cancel_target_ids: 接管旧委托
        now,                   # last_action_time
        0,                     # retry_count
        3,                     # max_retries
        Int64(5000),           # timeout_ms
        now,                   # create_time
        "",                    # error_msg
        tpst                   # 可选止盈止损（默认 nothing）
    )
    
    # 注册到全局状态
    exec_active_tasks[task_id] = task
    exec_symbol_tasks[(strategy_id, symbol)] = task_id
    
    strategy_log(2, "[ExecutionEngineV2] 创建执行任务: task=$task_id, symbol=$symbol, side=$target_side, vol=$volume, bid=$bid_price, ask=$ask_price")
    
    # 启动评估
    if initial_phase == :canceling
        strategy_log(2, "[ExecutionEngineV2] 新任务接管旧委托撤单: task=$task_id, pending_cancels=$(join(canceled_ids, ","))")
    end
    evaluate!(task)
    
    return task_id
end

"""
    create_risk_close_task(trade_date, symbol, bid_price, ask_price, account_id, account_type, strategy_id)::String

创建风控清仓任务（task_type = :risk_close），用于将该 (strategy_id, symbol) 的所有持仓清空。

特性：
- 同 key 已有 :risk_close 任务时也会强制接管（force_cancel_task!）：
  使用新的 bid/ask 重建任务，避免旧任务因平仓价偏离行情而长时间无法成交；
- 同 key 已有 :normal/:locked 任务时强制接管；
- :risk_close 任务一旦活跃，create_exec_task 创建普通任务时会被拒绝，直至该任务进入 :completed/:failed。

参数：
- trade_date: 交易日 YYYYMMDD
- symbol: 合约代码
- bid_price/ask_price: 当前买一/卖一价（用于平仓限价单）
- account_id/account_type: 账户标识
- strategy_id: 策略ID
"""
function create_risk_close_task(trade_date::Integer, symbol::String,
                                bid_price::Integer, ask_price::Integer,
                                account_id::String, account_type::Integer,
                                strategy_id::String)::String
    trade_date = Int(trade_date)
    bid_price = Int64(bid_price)
    ask_price = Int64(ask_price)
    account_type = Int(account_type)

    key = (strategy_id, symbol)
    canceled_ids = String[]
    if haskey(exec_symbol_tasks, key)
        existing_task_id = exec_symbol_tasks[key]
        if haskey(exec_active_tasks, existing_task_id)
            existing_task = exec_active_tasks[existing_task_id]
            # 风控清仓任务也允许被新的风控清仓任务接管：
            # 旧任务的平仓价可能已偏离行情导致挂单无法成交，使用新的 bid/ask 重建任务能更快完成清仓。
            if existing_task.task_type == :risk_close
                strategy_log(3, "[ExecutionEngineV2] 风控清仓任务被新风控任务接管(刷新平仓价): old_task=$existing_task_id, old_bid=$(existing_task.bid_price), old_ask=$(existing_task.ask_price), new_bid=$bid_price, new_ask=$ask_price, strategy=$strategy_id, symbol=$symbol")
            else
                strategy_log(3, "[ExecutionEngineV2] 风控触发，强制接管现有任务: old_task=$existing_task_id, type=$(existing_task.task_type), strategy=$strategy_id, symbol=$symbol")
            end
            canceled_ids = force_cancel_task!(existing_task)
        end
        delete!(exec_symbol_tasks, key)
    end

    initial_phase = isempty(canceled_ids) ? :evaluating : :canceling
    now = now_ms()
    task_id = gen_task_id()
    task = ExecutionTask(
        trade_date,
        task_id,
        :risk_close,
        account_id,
        account_type,
        symbol,
        "long",                # target_side: 占位，:risk_close 不依赖该字段
        0,                     # volume: 占位，目标是清空所有持仓
        bid_price,
        ask_price,
        strategy_id,
        initial_phase,
        "",                    # last_sent_cl_order_id
        canceled_ids,          # last_cancel_target_ids
        now,                   # last_action_time
        0,                     # retry_count
        5,                     # max_retries: 风控允许更多重试
        Int64(5000),           # timeout_ms
        now,                   # create_time
        "",                    # error_msg
        nothing                # tpst: 风控清仓任务不挂 TP/SL
    )

    exec_active_tasks[task_id] = task
    exec_symbol_tasks[key] = task_id

    strategy_log(3, "[ExecutionEngineV2] 创建风控清仓任务: task=$task_id, strategy=$strategy_id, symbol=$symbol, bid=$bid_price, ask=$ask_price")
    if initial_phase == :canceling
        strategy_log(2, "[ExecutionEngineV2] 风控任务接管旧委托撤单: task=$task_id, pending_cancels=$(join(canceled_ids, ","))")
    end
    evaluate!(task)
    return task_id
end

"""
    check_all_tasks!()

遍历所有活跃任务，检查超时并执行评估。
"""
function check_all_tasks!()
    now = now_ms()
    
    # 收集需要处理的任务ID（避免在遍历时修改字典）
    task_ids = collect(keys(exec_active_tasks))
    
    for task_id in task_ids
        if !haskey(exec_active_tasks, task_id)
            continue
        end
        
        task = exec_active_tasks[task_id]

        # :armed 任务不受超时驱动（仅由 price_notify! 推动）
        if task.phase == :armed
            continue
        end

        # 检查超时
        elapsed = now - task.last_action_time
        if elapsed > task.timeout_ms
            strategy_log(3, "[ExecutionEngineV2] 任务超时: task=$task_id, phase=$(task.phase), elapsed=$elapsed")
            
            task.retry_count += 1
            if task.retry_count >= task.max_retries
                task.phase = :failed
                task.error_msg = "任务超时次数超过上限"
                finalize_task!(task)
            else
                # 切回评估阶段重新评估
                task.phase = :evaluating
                evaluate!(task)
            end
        else
            # 未超时，执行常规评估
            evaluate!(task)
        end
    end
end

"""
    get_task_status(task_id::String)

查询任务状态。
返回: :evaluating, :canceling, :closing, :opening, :completed, :failed, 或 nothing(任务不存在)
"""
function get_task_status(task_id::String)
    if haskey(exec_active_tasks, task_id)
        return exec_active_tasks[task_id].phase
    end
    return nothing
end

"""
    cancel_exec_task(task_id::String)::Bool

取消指定任务。
"""
function cancel_exec_task(task_id::String)::Bool
    if !haskey(exec_active_tasks, task_id)
        return false
    end
    
    task = exec_active_tasks[task_id]
    
    if task.phase in [:completed, :failed]
        # 任务已结束
        return false
    end
    
    # 查询并撤销所有未终态委托
    try
        sid = task.strategy_id
        symbol = task.symbol
        all_pending = oms_query_pending_orders[](sid, symbol, 3, 3)
        
        if !isempty(all_pending)
            strategy_log(2, "[ExecutionEngineV2] 用户取消任务，撤销相关委托: task=$task_id")
            td_cancel_order(task.account_id, task.account_type, all_pending, true)
        end
    catch e
        strategy_log(3, "[ExecutionEngineV2] 取消任务撤单异常: task=$task_id, error=$e")
    end
    
    # 标记为失败
    task.phase = :failed
    task.error_msg = "用户取消"
    finalize_task!(task)
    
    return true
end

"""
    get_active_tasks()::Vector{String}

获取所有活跃任务的ID列表。
"""
function get_active_tasks()::Vector{String}
    return collect(keys(exec_active_tasks))
end

export create_exec_task, create_risk_close_task, cancel_exec_task, engine_notify!, price_notify!, check_all_tasks!
export get_task_status, get_active_tasks
export ExecutionTask, TPSTSpec
export str_to_carray_memcpy