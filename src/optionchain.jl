using Dates
import FinancialStruct.cFuCodeInfo as cCodeInfo 

const product_expire_month = Dict{String, Vector{Tuple{UInt32, String}}}()
const product_call = Dict{String, Vector{String}}()
const product_put = Dict{String, Vector{String}}()
const exchange_products = Dict{String, Vector{String}}()
const expire_month_strike = Dict{String, Vector{Int64}}()
const product_month_strike_symbol = Dict{Tuple{String, Char, Int64}, String}()
const product_month = Dict{Tuple{String, UInt32}, String}()

struct option_info
    symbol::String
    exchange::String
    product::String
    product_month::String
    year::UInt32
    month::UInt32
    option_type::Char
    strike::Int64
end

function parse_option_code(code::String; ref_year::Integer=year(today()))::option_info
    # 分离交易所和合约代码
    exchange = ""
    symbol = code
    if occursin('.', code)
        parts = split(code, '.', limit=2)
        exchange = string(parts[1])
        symbol = string(parts[2])
    end

    opt_year = 0
    opt_month = 0
    option_type = '\0'
    strike = ""
    product = ""
    product_month = ""
    if occursin('-', symbol)
        # 格式1: 品种YYMM-C/P-行权价 (CFFEX, DCE, GFEX)
        m = match(r"^([A-Za-z]+)(\d{4})-([CP])-(\d+)$", symbol)
        if m !== nothing
            product = m.captures[1]
            product_month = string(exchange,".",m.captures[1], m.captures[2])
            ym = m.captures[2]
            option_type = m.captures[3][1]
            strike = m.captures[4]
            opt_year = 2000 + parse(UInt32, ym[1:2])
            opt_month = parse(UInt32, ym[3:4])
        end
    else
        # 紧凑格式: 用 \d[CP]\d 定位期权类型字符
        m = match(r"^([A-Za-z]+)(\d+)([CP])(\d+)$", symbol)
        if m !== nothing
            product = m.captures[1]
            ym = m.captures[2]
            option_type = m.captures[3][1]
            strike = m.captures[4]
            product_month = string(exchange,".",m.captures[1], m.captures[2])
            if length(ym) == 4
                # 格式2: SHFE/INE — 4位年月
                opt_year = 2000 + parse(UInt32, ym[1:2])
                opt_month = parse(UInt32, ym[3:4])
            elseif length(ym) == 3
                # 格式3: CZCE — 3位年月（首位=年末位，后两位=月）
                year_digit = parse(UInt32, ym[1:1])
                opt_month = parse(UInt32, ym[2:3])
                # 根据参考年推断完整年份
                decade = ref_year ÷ 10 * 10
                candidate = decade + year_digit
                if candidate < ref_year - 2
                    candidate += 10
                end
                opt_year = candidate
            end
        end
    end
    return option_info(code, exchange, string(exchange,",",product), product_month,
            UInt32(opt_year), UInt32(opt_month), 
            uppercase(option_type), parse(Int64, strike))
end

function option_chain_init(; ref_year::Integer=year(today()))
    product_class = Cchar('2')
    exchange_id = ""
    codeinfos = get_realtime_codelist(exchange_id, product_class)
    option_chain_init(codeinfos; ref_year=ref_year)
    product_class = Cchar('6')
    codeinfos = get_realtime_codelist(exchange_id, product_class)
    option_chain_init(codeinfos; ref_year=ref_year)
    return nothing
end

function option_chain_init(codeinfos::Vector{cCodeInfo}; ref_year::Integer=year(today()))
    for codeinfo in codeinfos
        if codeinfo.is_halt == 1
            continue
        end
        symbol = unsafe_string(pointer(reinterpret.(UInt8, codeinfo.symbol)))
        option_info = parse_option_code(symbol; ref_year=ref_year)
        #expire_month = option_info.year*100 + option_info.month
        expire_date = codeinfo.trade_date_out
        product = option_info.product
        product_month = option_info.product_month
        option_type = option_info.option_type
        strike = option_info.strike
        # 添加期权到期日到对应品种的到期月份列表
        if !haskey(product_expire_month, product)
            product_expire_month[product] = Tuple{UInt32, String}[]
        end
        if (expire_date, product_month) in product_expire_month[product]
        else
            push!(product_expire_month[product], (expire_date, product_month))
        end
        # 添加期权合约到对应品种的看涨期权和看跌期权列表
        if !haskey(product_call, product)
            product_call[product] = String[]
            product_put[product] = String[]
        end
        if option_type == 'C'
            push!(product_call[product], symbol)
        elseif option_type == 'P'
            push!(product_put[product], symbol)
        end
        # 添加期权合约品种到对应交易所的品种列表
        if !haskey(exchange_products, option_info.exchange)
            exchange_products[option_info.exchange] = String[]
        end
        if option_info.product in exchange_products[option_info.exchange]
        else
            push!(exchange_products[option_info.exchange], option_info.product)
        end
        # 添加期权合约行权价到对应交易所和品种的行权价列表
        if !haskey(expire_month_strike, product_month)
            expire_month_strike[product_month] = Int64[]
        end
        if strike in expire_month_strike[product_month]
        else
            push!(expire_month_strike[product_month], strike)
        end
        # 建立品种、期权类型和行权价到对应期权合约的字典
        product_month_strike_symbol[(product_month, option_type, strike)] = symbol
        # 建立品种和到期月份到期权合约带月份品种的字典
        product_month[(product, expire_date)] = product_month
    end
    for key in keys(product_expire_month)
        sort!(product_expire_month[key]; by=x->x[1])
    end
    for key in keys(expire_month_strike)
        sort!(expire_month_strike[key])
    end
    return nothing
end

# 根据价格获取期权合约代码, 
# level为0时, 返回平值期权
# level为1,2,3,...时, 返回实值期权, 实一，实二，实三，...
# level为-1,-2,-3,...时, 返回虚值期权, 虚一，虚二，虚三，...
function get_tm_option(price::Integer, product_month::String, option_type::Char, level::Integer)::String
    strikes = expire_month_strike[product_month]
    idx = argmin(abs.(v .- price))
    if option_type == 'C'
        idx = idx + level
    elseif option_type == 'P'
        idx = idx - level
    end
    idx = min(idx, length(strikes))
    idx = max(idx, 1)
    strike = strikes[idx]
    symbol = product_month_strike_symbol[(product_month, option_type, strike)]
    return symbol
end

export option_chain_init, get_tm_option, option_info
export product_expire_month, product_call, product_put, exchange_products, 
export expire_month_strike, product_month_strike_symbol, product_month
