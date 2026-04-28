module HFTCTP
###using StringEncodings
using CBinding
using Pkg.Artifacts
using FinancialStruct:cOnlyTBTickData,cSecurityTickData,cTickByTickData
using FinancialStruct:cIndexTickData  
using FinancialStruct:cFuturesTickData
using FinancialStruct:cOptionsTickData
using FinancialStruct:cSecurityKdata
using FinancialStruct:cFuCodeInfo as cCodeInfo
using FinancialStruct:cTradeDate
using FinancialStruct:cQxData
using FinancialStruct:cOrderQueueItemData  
using FinancialStruct:cOrderQueueData
using FinancialStruct:cTickByTickEntrust
using FinancialStruct:cTickByTickTrade
using FinancialStruct:cDateUpdateData
import FinancialStruct.cFuOrderReq as cOrderReq
using FinancialStruct:cCancelReq     
using FinancialStruct:cCancelDetail
using FinancialStruct:cOrderRsp    
import FinancialStruct.cFuOrder as cOrder      
import FinancialStruct.cFuTrade as cTrade       
import FinancialStruct.cFuPosition as cPosition    
using FinancialStruct:cCash        
using FinancialStruct:cIndicator
using FinancialStruct:cContractStat
using Dates
using OrderManager

# 使用 Artifacts 动态加载库文件
function __init__()
    # 确保 artifact 可用
    lib_dir = artifact"hftctp_lib"
    # 根据平台设置库路径
    global dlfile
    if Sys.iswindows()
        dlfile = joinpath(lib_dir, "hft.dll")
    elseif Sys.islinux()
        # 动态查找 .so 文件（适配不同版本号）
        files = readdir(lib_dir)
        so_file = filter(f -> startswith(f, "libhft.so."), files)
        if !isempty(so_file)
            # 优先选择带版本号的（文件名最长的）
            dlfile = joinpath(lib_dir, sort(so_file, by=length, rev=true)[1])
        else
            @error "libhft.so not found in $lib_dir"
        end
    end
    # 验证库文件是否存在
    if !isfile(dlfile)
        @error "hftctp library files not found. Please make sure the package is installed correctly."
    end
    try
        global lib = Libc.Libdl.dlopen(dlfile)
    catch e
        @error "Failed to load library: $dlfile" exception=e
        rethrow(e)
    end
end

#lib = "C:/workspace/ctp/win64/hft/lib/hft.dll"
#######################################strategy_api###############################################
"""
    strategy_init(config_dir::String="./", log_dir::String="./")
 * 读取策略配置文件，初始化策略API接口。
 *
 * @param config_dir    策略配置文件目录，默认是当前可执行程序目录，编码为utf8
 * @param log_dir       策略日志文件目录，默认是当前可执行程序目录，编码为utf8
 *
 * @return              成功返回0，失败返回错误码，错误码定义在error.h文件中
"""
function strategy_init(config_dir::String="./", log_dir::String="./")
    sym = Libc.Libdl.dlsym(lib, :strategy_init)   # 获得用于调用函数的符号
    err = ccall(sym, Int32, (Ptr{UInt8}, Ptr{UInt8}), config_dir, log_dir)
    return err
end
export strategy_init

"""
    strategy_init_with_config_dict(config::Dict{String,String}, log_dir::String="./")
 * 使用给定的配置参数字典初始化策略API接口。
 *
 * @param config_dict   策略配置参数字典
 * @param log_dir       策略日志文件目录，默认是当前可执行程序目录，编码为utf8
 *
 * @return              成功返回0，失败返回错误码，错误码定义在error.h文件中
"""
function strategy_init_with_config_dict(config::Dict{String,String}, log_dir::String="./")
    sym1 = Libc.Libdl.dlsym(lib, :strategy_config_dict_create)   # 获得用于调用函数的符号
    sym2 = Libc.Libdl.dlsym(lib, :strategy_config_dict_set_param)   # 获得用于调用函数的符号
    sym3 = Libc.Libdl.dlsym(lib, :strategy_init_with_config_dict)   # 获得用于调用函数的符号
    sym4 = Libc.Libdl.dlsym(lib, :strategy_config_dict_destroy)   # 获得用于调用函数的符号
    config_dict_c = ccall(sym1, Ptr{Cvoid}, ())
    for (k, v) in config
        ccall(sym2, Cint, (Ptr{Cvoid}, Ptr{UInt8}, Ptr{UInt8}), config_dict_c, k, v)
    end 
    err = ccall(sym3, Cint, (Ptr{Cvoid}, Ptr{UInt8}), config_dict_c, log_dir)
    err2 = ccall(sym4, Cint, (Ptr{Cvoid},), config_dict_c)
    return err, err2
end
export strategy_init_with_config_dict

"""
    strategy_exit()
 * 退出并停止策略运行。该函数调用后strategy_run接口将退出运行。
 *
 * @return              成功返回0，失败返回错误码，错误码定义在error.h文件中
"""
function strategy_exit()
    sym = Libc.Libdl.dlsym(lib, :strategy_exit)
    err = ccall(sym, Cint, ())
    return err
end
export strategy_exit

"""
    strategy_set_exit_callback(on_exit::Function, user_data::Ptr{Cvoid}=C_NULL)::Cint
 * 设置策略退出事件回调函数
 *
 * @param on_exit       策略退出事件回调方法
 * @param user_data     用户自定义参数
 *
 * @return              成功返回0，失败返回错误码，错误码定义在error.h文件中
"""
function strategy_set_exit_callback(on_exit_c::Ptr{Nothing}, user_data::Ptr{Cvoid}=C_NULL)::Cint
    sym = Libc.Libdl.dlsym(lib, :strategy_set_exit_callback)
    err = ccall(sym, Int32, (Ptr{Cvoid}, Ptr{Cvoid}), on_exit_c, user_data)
    return err
end
export  strategy_set_exit_callback

"""
    strategy_set_timer_callback(on_timer::Function, user_data::Ptr{Cvoid}=C_NULL)::Cint
 * 设置定时器回调方法
 *
 * @param on_timer      定时器回调方法
 * @param user_data     用户自定义参数
 *
 * @return              成功返回0，失败返回错误码，错误码定义在error.h文件中
"""
function strategy_set_timer_callback(on_timer_c::Ptr{Nothing}, user_data::Ptr{Cvoid}=C_NULL)::Cint
    sym = Libc.Libdl.dlsym(lib, :strategy_set_timer_callback)
    err = ccall(sym, Int32, (Ptr{Cvoid}, Ptr{Cvoid}), on_timer_c, user_data)
    return err
end
export strategy_set_timer_callback

"""
    strategy_set_timer(interval::Integer)::Cint
 * 设置定时器触发时间间隔。
 *
 * @param interval      定时器触发间隔(毫秒)，精确到毫秒
 *
 * @return              成功返回0，失败返回错误码，错误码定义在error.h文件中
"""
function strategy_set_timer(interval::Integer)::Cint
    sym = Libc.Libdl.dlsym(lib, :strategy_set_timer)
    err = ccall(sym, Int32, (Cint, ), interval)
    return err
end
export strategy_set_timer

"""
    strategy_clear_timer(interval::Integer)::Cint
 * 取消指定时间间隔定时器。
 *
 * @param interval      定时器触发间隔(毫秒)，精确到毫秒
 *
 * @return              成功返回0，失败返回错误码，错误码定义在error.h文件中
"""
function strategy_clear_timer(interval::Integer)::Cint
    sym = Libc.Libdl.dlsym(lib, :strategy_clear_timer)
    err = ccall(sym, Int32, (Cint, ), interval)
    return err
end
export strategy_clear_timer

"""
    strategy_set_day_schedule_task_callback(on_day_schedule_task::Function, user_data::Ptr{Cvoid}=C_NULL)::Cint
 * 设置交易日定时任务回调方法
 *
 * @param on_day_schedule_task            交易日定时任务回调方法
 * @param user_data                       用户自定义参数
 *
 * @return              成功返回0，失败返回错误码，错误码定义在error.h文件中
"""
function strategy_set_day_schedule_task_callback(on_day_schedule_task_c::Ptr{Nothing}, user_data::Ptr{Cvoid}=C_NULL)::Cint
    sym = Libc.Libdl.dlsym(lib, :strategy_set_day_schedule_task_callback)
    err = ccall(sym, Int32, (Ptr{Cvoid}, Ptr{Cvoid}), on_day_schedule_task_c, user_data)
    return err
end
export strategy_set_day_schedule_task_callback

"""
    strategy_set_day_schedule_task(timepoint::Integer)::Cint
 * 设置给定时间执行的交易日定时任务。
 *
 * @param timepoint          定时任务执行时间: HHMMSS，精确到秒
 *
 * @return              成功返回0，失败返回错误码，错误码定义在error.h文件中
"""
function strategy_set_day_schedule_task(timepoint::Integer)::Cint
    sym = Libc.Libdl.dlsym(lib, :strategy_set_day_schedule_task)
    err = ccall(sym, Int32, (Cint, ), timepoint)
    return err
end
export strategy_set_day_schedule_task

"""
    strategy_clear_day_schedule_task(timepoint::Integer)::Cint
 * 取消指定执行时间的交易日定时任务。
 *
 * @param timepoint          定时任务执行时间: HHMMSS，精确到秒
 *
 * @return              成功返回0，失败返回错误码，错误码定义在error.h文件中
"""
function strategy_clear_day_schedule_task(timepoint::Integer)::Cint
    sym = Libc.Libdl.dlsym(lib, :strategy_clear_day_schedule_task)
    err = ccall(sym, Int32, (Cint, ), timepoint)
    return err
end
export strategy_clear_day_schedule_task

"""
    strategy_set_params_setting_callback(on_params_setting::Function, user_data::Ptr{Cvoid}=C_NULL)::Cint
 * 设置策略参数设置回调方法。
 *
 * @param on_params_setting       策略参数设置回调方法
 * @param user_data               用户自定义参数
"""
function strategy_set_params_setting_callback(on_params_setting_c::Ptr{Nothing}, user_data::Ptr{Cvoid}=C_NULL)::Cint
    sym = Libc.Libdl.dlsym(lib, :strategy_set_params_setting_callback)
    err = ccall(sym, Int32, (Ptr{Cvoid}, Ptr{Cvoid}), on_params_setting_c, user_data)
    return err
end
export strategy_set_params_setting_callback

"""
    strategy_report_params(params_json::String)::Cint
 * 报告策略参数。
 * 一般在策略启动时通过该API向客户端报告策略运行参数，
 * 设置一次即可，策略运行过程中可通过客户端修改运行参数，
 * 更新后的参数存在内存中，不落地磁盘
 *
 * @param params_json   策略参数(json字符串格式)
"""
function strategy_report_params(params_json::String)::Cint
    sym = Libc.Libdl.dlsym(lib, :strategy_report_params)
    ccall(sym, Int32, (Ptr{UInt8}, ), params_json)
end
export strategy_report_params

"""
    strategy_report_indexes(indexes_json::String)::Cint
 * 报告自定义策略指标。
 * 可以在策略运行过程中实时通过该接口向客户端报告自定义策略指标，
 * 通过客户端界面查看当前的策略指标数据。
 *
 * @param params_json   策略指标(json字符串格式)
"""
function strategy_report_indexes(indexes_json::String)::Cint
    sym = Libc.Libdl.dlsym(lib, :strategy_report_indexes)
    ccall(sym, Int32, (Ptr{UInt8}, ), indexes_json)
end
export strategy_report_indexes

"""
    strategy_run(mode::Integer=0)::Cint
 * 调用接口的线程阻塞执行策略事件循环，直到策略正常退出或者异常终止。
 * 所有策略回调函数(包括行情，交易接口回调)都会在调用线程中调用。
 *
 * @param mode          0 - 默认模式,
 *                      1 - spin模式，通过死循环检测事件队列中是否
 *                          有新的事件到达。
 *                      2 - 以多线程启动,该模式不会阻塞strategy_run
 *
 * @return              正常退出返回0，异常退出返回错误码，
 *                      错误码定义在error.h文件中
"""
function strategy_run(mode::Integer=0)::Cint
    sym = Libc.Libdl.dlsym(lib, :strategy_run)
    err = ccall(sym, Int32, (Cint,), mode)
end
export strategy_run

"""
    strategy_poll(timeout::Integer=-1)::Cint
 * 执行一次策略事件处理循环。
 *
 * @param timeout       等待下一个事件超时时间(毫秒)。
 *                      0 - 不等待，-1 - 无限等待直到下一个事件触发。
 *
 * @return              正常退出返回0，异常退出返回错误码，
 *                      错误码定义在error.h文件中
"""
function strategy_poll(timeout::Integer=-1)::Cint
    sym = Libc.Libdl.dlsym(lib, :strategy_poll)
    err = ccall(sym, Int32, (Cint,), timeout)
    return err
end
export strategy_poll

"""
    strategy_get_exec_status()::Cint
 * 获取当前策略执行状态。
 *
 * @return              策略执行状态，参考StrategyExecStatus定义。
 """
function strategy_get_exec_status()::Cint
    sym = Libc.Libdl.dlsym(lib, :strategy_get_exec_status)
    err = ccall(sym, Int32, ())
    return err
end
export strategy_get_exec_status

"""
    strategy_get_datetime()::NTuple{2,Cint}
 * 获取当前日期时间: 对于回测模式 - 返回回测执行当前日期时间，
 * 对于实盘和模拟模式返回当前机器的系统时间。
 *
 * @param o_date        输出日期(YYYYMMDD)，注意对于期货市场这里返回的是实际日期而不是交易日。
 * @param o_time        输出时间(HHMMSSmmm)。
 *
 * @return              正常退出返回0，异常退出返回错误码，
 *                      错误码定义在error.h文件中
"""
function strategy_get_datetime()::NTuple{2,Cint}
    o_date = Ref{Cint}()
    o_time = Ref{Cint}()
    sym = Libc.Libdl.dlsym(lib, :strategy_get_datetime)
    ccall(sym, Int32, (Ptr{Cint}, Ptr{Cint}), o_date, o_time)
    return o_date.x, o_time.x
end
export strategy_get_datetime

"""
    strategy_get_millseconds()::Int64
 * 获取当前时间(单位毫秒): 对于回测模式 - 返回回测执行到当前位置，
 * 回测时间线中经过的毫秒数，对于实盘和模拟模式返回系统启动到当前
 * 时间点经过的毫秒数。
 *
 * @return              当前时间(单位毫秒)。
"""
function strategy_get_millseconds()::Int64
    sym = Libc.Libdl.dlsym(lib, :strategy_get_millseconds)
    ccall(sym, Int64, ())
end
export strategy_get_millseconds

"""
    strategy_log(level::Integer, message::String, is_gbk::Bool=false)::Cvoid
 * 记录策略日志，日志文件最终编码格式为utf8
 *
 * @param level         日志级别: 1:debug 2:Info 3:Warn 4:Error
 * @param message       日志消息，默认输入的是utf8编码
 * @param is_gbk        当输入日志为gbk时传入true，默认是false
"""
function strategy_log(level::Integer, message::String, is_gbk::Bool=false)::Cvoid
    sym = Libc.Libdl.dlsym(lib, :strategy_log)
    ccall(sym, Cvoid, (Cint, Ptr{UInt8}, Bool), level, message, is_gbk)
end
export strategy_log

"""
    strategy_exit_reason(reason::Integer)::String
 * 策略退出原因字符形式，方便输出日志查看
 *
 * @param reason        策略退出原因
"""
function strategy_exit_reason(reason::Integer)::String
    sym = Libc.Libdl.dlsym(lib, :strategy_exit_reason)
    reason_char = ccall(sym, Ptr{Cchar}, (Cint, ), reason)
    unsafe_string(reason_char)
end
export strategy_exit_reason

"""
    strategy_exec_status(status::Integer)::String
 * 策略运行状态字符形式，方便输出日志查看
 *
 * @param status        策略运行状态
"""
function strategy_exec_status(status::Integer)::String
    sym = Libc.Libdl.dlsym(lib, :strategy_exec_status)
    status_char = ccall(sym, Ptr{Cchar}, (Cint, ), status)
    unsafe_string(status_char)
end
export strategy_exec_status

"""
    strategy_exec_mode(exec_mode::Integer)::String
 * 策略运行模式字符形式，方便输出日志查看
 *
 * @param status        策略运行模式
"""
function strategy_exec_mode(exec_mode::Integer)::String
    sym = Libc.Libdl.dlsym(lib, :strategy_exec_mode)
    exec_mode_char = ccall(sym, Ptr{Cchar}, (Cint, ), exec_mode)
    unsafe_string(exec_mode_char)
end
export strategy_exec_mode

"""
    strategy_json_config()
 * 返回策略配置，json格式
"""
function strategy_json_config()
    sym = Libc.Libdl.dlsym(lib, :strategy_json_config)
    json = ccall(sym, Ptr{Cchar}, ())
    unsafe_string(json)
end
export strategy_json_config

"""
on_strategy_trading_span(span_status::UInt8, rc::Cint, trading_day::Cint, cur_date::Cint, 
                     cur_time::Cint, span_name::Ptr{UInt8}, user_data::Ptr{Cvoid})::Cvoid
 * @brief 当交易时间段开始之后或结束之前会调用此回调，在回调中可以进行交易时段内的准备工作或清理工作
 * @param span_status       交易时间段状态，true - 进入交易时间段，false - 退出交易时间段
 * @param rc                柜台连接结果，0 - 成功，其他 - 失败 （如果是结束交易时段的回调本参数无效）
 * @param trading_day       日期(YYYYMMDD), 归属日
 * @param cur_date          日期(YYYYMMDD)，实际日期
 * @param time              时间(HHMMSSmmm)
 * @param span_name         交易时间段标识符，根据配置文件
 * @param user_data         用户自定义参数
 *
 */
   strategy_set_trading_span_callback(on_strategy_trading_span_c::Ptr{Nothing}, user_data::Ptr{Cvoid}=C_NULL)
 * @brief 设置交易时间段变化回调函数, 当交易时间段开始或结束时会调用此回调
 * @param on_strategy_trading_span_c      交易时间段变化回调方法
 * @param user_data                          用户自定义参数
 *
 */
"""
function strategy_set_trading_span_callback(on_strategy_trading_span_c::Ptr{Nothing}, user_data::Ptr{Cvoid}=C_NULL)
    sym = Libc.Libdl.dlsym(lib, :strategy_set_trading_span_callback)
    ccall(sym, Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}), on_strategy_trading_span_c, user_data)
    return nothing
end

"""
   on_strategy_trading_day(trading_day::Cint, cur_date::Cint, time::Cint, day_status::UInt8, user_data::Ptr{Cvoid})
   @brief 当交易日开始或结束时会调用此回调，在回调中可以进行交易日内的准备工作或清理工作
 *
 * @param trading_day       日期(YYYYMMDD), 归属日
 * @param cur_date          日期(YYYYMMDD)，实际日期
 * @param time              时间(HHMMSSmmm)
 * @param day_status        交易日状态，true - 进入交易日，false - 退出交易日
 * @param user_data         用户自定义参数
*/
/**
   strategy_set_trading_day_callback
   @brief 设置交易日变化回调函数, 当交易日开始或结束时会调用此回调  
 *
 * @param on_strategy_trading_day_c   交易日变化回调方法
 * @param user_data                      用户自定义参数
 *
 */
"""
function strategy_set_trading_day_callback(on_strategy_trading_day_c::Ptr{Nothing}, user_data::Ptr{Cvoid}=C_NULL)
    sym = Libc.Libdl.dlsym(lib, :strategy_set_trading_day_callback)
    ccall(sym, Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}), on_strategy_trading_day_c, user_data)
    return nothing
end

##############################################md_api################################################################
#/************************ 获取历史行情相关接口 begin ***************************/

export cSecurityTickData
export cIndexTickData  
export cFuturesTickData
export cOptionsTickData
export cSecurityKdata
export cCodeInfo
export cTradeDate
export cQxData
export cOrderQueueItemData  
export cOrderQueueData
export cTickByTickEntrust
export cTickByTickTrade
export cTickByTickData
export cDateUpdateData 

"""
    get_security_ticks(symbols::Vector{String}, begin_time::String, end_time::String)::Vector{cSecurityTickData}
 * 获取指定时间段的证券历史Tick数据，接口支持单个代码或多个代码组合获取数据。
 *
 * @param symbol_list   证券代码列表，以逗号分开的市场.证券代码，如"sh.600726,sz.000729"
 * @param begin_time    开始时间，YYYY/MM/DD hh:mm:ss,如"2017/07/05 9:0:0"
 * @param end_time      结束时间，YYYY/MM/DD hh:mm:ss,如"2017/07/05 10:0:0"
 * @param std           获取的证券tick数据
 * @param count         获取的数据个数
 * @return              返回Vector{cSecurityTickData}
"""
function get_security_ticks(symbols::Vector{String}, begin_time::String, end_time::String)::Vector{cSecurityTickData}
    len = Ref{Cint}()
    std = Ref{Cptr{cSecurityTickData}}(C_NULL)
    symbol_list = join(symbols, ",")
    sym = Libc.Libdl.dlsym(lib, :get_security_ticks)
    err = ccall(sym, Int32, (Ptr{UInt8}, Ptr{UInt8}, Ptr{UInt8}, Cptr{Cptr{cSecurityTickData}}, Ptr{Cint}), symbol_list, begin_time, end_time, std, len)
    if err == 0
        res = cSecurityTickData[]
        for i = 1:len.x
            stdi = unsafe_load(std[] + i - 1)
            push!(res, stdi)
        end
        return res
    else
        return cSecurityTickData[]
    end
end
export get_security_ticks

"""
    get_index_ticks(symbols::Vector{String}, begin_time::String, end_time::String)::Vector{cIndexTickData}
 * 获取指定时间段的指数历史Tick数据，接口支持单个代码或多个代码组合获取数据。
 *
 * @param symbol_list   指数代码列表，以逗号分开的市场.证券代码，如\"sh.000001,sz.399992\"
 * @param begin_time    开始时间，YYYY/MM/DD hh:mm:ss,如"2017/07/05 9:0:0"
 * @param end_time      结束时间，YYYY/MM/DD hh:mm:ss,如"2017/07/05 10:0:0"
 * @param itd           获取的指数tick数据
 * @param count         获取的数据个数
 * @return              返回Vector{cIndexTickData}
"""
function get_index_ticks(symbols::Vector{String}, begin_time::String, end_time::String)::Vector{cIndexTickData}
    len = Ref{Cint}()
    std = Ref{Cptr{cIndexTickData}}(C_NULL)
    symbol_list = join(symbols, ",")
    sym = Libc.Libdl.dlsym(lib, :get_index_ticks)
    err = ccall(sym, Int32, (Ptr{UInt8}, Ptr{UInt8}, Ptr{UInt8}, Cptr{Cptr{cIndexTickData}}, Ptr{Cint}), symbol_list, begin_time, end_time, std, len)
    if err == 0
        res = cIndexTickData[]
        for i = 1:len.x
            stdi = unsafe_load(std[] + i - 1)
            push!(res, stdi)
        end
        return res
    else
        return cIndexTickData[]
    end
end
export get_index_ticks

"""
    get_futures_ticks(symbols::Vector{String}, begin_time::String, end_time::String)::Vector{cFuturesTickData}
 * 获取指定时间段的期货历史Tick数据，接口支持单个代码或多个代码组合获取数据。
 *
 * @param symbol_list   期货代码列表，以逗号分开的市场.证券代码，如\"cffex.if1803,cffex.ic1806\"
 * @param begin_time    开始时间，YYYY/MM/DD hh:mm:ss,如\"2017/07/05 9:0:0\"
 * @param end_time      结束时间，YYYY/MM/DD hh:mm:ss,如\"2017/07/05 10:0:0\"
 * @param ftd           获取的期货tick数据
 * @param count         获取的数据个数
 * @return              返回Vector{cFuturesTickData}
"""
function get_futures_ticks(symbols::Vector{String}, begin_time::String, end_time::String)::Vector{cFuturesTickData}
    len = Ref{Cint}()
    std = Ref{Cptr{cFuturesTickData}}(C_NULL)
    symbol_list = join(symbols, ",")
    sym = Libc.Libdl.dlsym(lib, :get_futures_ticks)
    err = ccall(sym, Int32, (Ptr{UInt8}, Ptr{UInt8}, Ptr{UInt8}, Cptr{Cptr{cFuturesTickData}}, Ptr{Cint}), symbol_list, begin_time, end_time, std, len)
    if err == 0
        res = cFuturesTickData[]
        for i = 1:len.x
            stdi = unsafe_load(std[] + i - 1)
            push!(res, stdi)
        end
        return res
    else
        return cFuturesTickData[]
    end
end
export get_futures_ticks

"""
    get_options_ticks(symbols::Vector{String}, begin_time::String, end_time::String)::Vector{cOptionsTickData}
 * 获取指定时间段的期权历史Tick数据，接口支持单个代码或多个代码组合获取数据。
 *
 * @param symbol_list   期权代码列表，以逗号分开的市场.证券代码，如\"shop.10210201,shop.1201021\"
 * @param begin_time    开始时间，YYYY/MM/DD hh:mm:ss,如\"2017/07/05 9:0:0\"
 * @param end_time      结束时间，YYYY/MM/DD hh:mm:ss,如\"2017/07/05 10:0:0\"
 * @param otd           获取的期权tick数据
 * @param count         获取的数据个数
 * @return              返回Vector{cOptionsTickData}
"""
function get_options_ticks(symbols::Vector{String}, begin_time::String, end_time::String)::Vector{cOptionsTickData}
    len = Ref{Cint}()
    std = Ref{Cptr{cOptionsTickData}}(C_NULL)
    symbol_list = join(symbols, ",")
    sym = Libc.Libdl.dlsym(lib, :get_options_ticks)
    err = ccall(sym, Int32, (Ptr{UInt8}, Ptr{UInt8}, Ptr{UInt8}, Cptr{Cptr{cOptionsTickData}}, Ptr{Cint}), symbol_list, begin_time, end_time, std, len)
    if err == 0
        res = cOptionsTickData[]
        for i = 1:len.x
            stdi = unsafe_load(std[] + i - 1)
            push!(res, stdi)
        end
        return res
    else
        return cOptionsTickData[]
    end
end
export get_options_ticks

"""
    get_tickbyticks(symbols::Vector{String}, begin_time::String, end_time::String)::Vector{cTickByTickData}
 * 获取指定时间段的历史逐笔行情数据，接口支持单个代码或多个代码组合获取数据。
 *
 * @param symbol_list   证券代码列表，以逗号分开的市场.证券代码，如"sh.600000,sz.300033"
 * @param begin_time    开始时间，YYYY/MM/DD hh:mm:ss,如"2017/07/05 9:0:0"
 * @param end_time      结束时间，YYYY/MM/DD hh:mm:ss,如"2017/07/05 10:0:0"
 * @param tbts          获取的逐笔行情数据
 * @param count         获取的数据个数
 * @return              返回Vector{cTickByTickData}
"""
function get_tickbyticks(symbols::Vector{String}, begin_time::String, end_time::String)::Vector{cTickByTickData}
    len = Ref{Cint}()
    std = Ref{Cptr{cTickByTickData}}(C_NULL)
    symbol_list = join(symbols, ",")
    sym = Libc.Libdl.dlsym(lib, :get_tickbyticks)
    err = ccall(sym, Int32, (Ptr{UInt8}, Ptr{UInt8}, Ptr{UInt8}, Cptr{Cptr{cTickByTickData}}, Ptr{Cint}), symbol_list, begin_time, end_time, std, len)
    if err == 0
        res = cTickByTickData[]
        for i = 1:len.x
            stdi = unsafe_load(std[] + i - 1)
            push!(res, stdi)
        end
        return res
    else
        return cTickByTickData[]
    end
end
export get_tickbyticks

##
#/**
# * 获取指定时间段的历史逐笔行情数据，接口支持单个代码或多个代码组合获取数据。
# * 查询结果以回调方式返回
# *
# * @param symbol_list   证券代码列表，以逗号分开的市场.证券代码，如"sh.600000,sz.300033"
# * @param begin_time    开始时间，YYYY/MM/DD hh:mm:ss,如"2017/07/05 9:0:0"
# * @param end_time      结束时间，YYYY/MM/DD hh:mm:ss,如"2017/07/05 10:0:0"
# * @param tbts          获取的逐笔行情数据
# * @param count         获取的数据个数
# * @return              成功返回0，失败返回错误码
# */
#HFT_API int get_tickbyticks_cb(const char* symbol_list, const char* begin_time,
#                               const char* end_time, MDTickByTickCallback cb, 
#                               void* user_data);
##

"""
    get_orderqueues(symbols::Vector{String}, begin_time::String, end_time::String)::Vector{cOrderQueueData}
 * 获取指定时间段的历史委托队列数据，接口支持单个代码或多个代码组合获取数据。
 *
 * @param symbol_list   证券代码列表，以逗号分开的市场.证券代码，如"sh.600000,sz.300033"
 * @param begin_time    开始时间，YYYY/MM/DD hh:mm:ss,如"2017/07/05 9:0:0"
 * @param end_time      结束时间，YYYY/MM/DD hh:mm:ss,如"2017/07/05 10:0:0"
 * @param oqs           获取的委托队列数据
 * @param count         获取的数据个数
 * @return              返回Vector{cOrderQueueData}
"""
function get_orderqueues(symbols::Vector{String}, begin_time::String, end_time::String)::Vector{cOrderQueueData}
    len = Ref{Cint}()
    std = Ref{Cptr{cOrderQueueData}}(C_NULL)
    symbol_list = join(symbols, ",")
    sym = Libc.Libdl.dlsym(lib, :get_orderqueues)
    err = ccall(sym, Int32, (Ptr{UInt8}, Ptr{UInt8}, Ptr{UInt8}, Cptr{Cptr{cOrderQueueData}}, Ptr{Cint}), symbol_list, begin_time, end_time, std, len)
    if err == 0
        res = cOrderQueueData[]
        for i = 1:len.x
            stdi = unsafe_load(std[] + i - 1)
            push!(res, stdi)
        end
        return res
    else
        return cOrderQueueData[]
    end
end
export get_orderqueues

"""
    get_security_kdata(symbols::Vector{String}, begin_time::String, end_time::String, frequency::String, fq::String)::Vector{cSecurityKdata}
 * 获取指定时间段的历史K线数据，
 * 支持任意分钟或天的证券K线数据获取.
 *
 * @param  symbol_list 证券代码列表，以逗号分开的市场.证券代码，如"sh.601211,sz.000001"
 * @param  begin_date  开始日期，如"2017/1/3"
 * @param  end_date    结束日期，如"2017/10/12",当基于分钟K线计算时日期跨度不能大于1年，基于日线计算则不受限制
 * @param  frequency   计算频率，单位"min"表示分钟K线，比如"5min","15min","30min", 大于1min且 120min % xmin == 0. 
 *                     单位"day"表示日，比如"5day","10day","30day",大于0即可。可以为"1min"或"1day"。
 * @param  fq          复权方式（前复权"before"、后复权"after"、不复权"none"）
 * @param  skd         获取的K线数据
 * @param  count       获取的K线数据个数
 * @return             返回Vector{cSecurityKdata}
"""
function get_security_kdata(symbols::Vector{String}, begin_time::String, end_time::String, frequency::String, fq::String)::Vector{cSecurityKdata}
    len = Ref{Cint}()
    std = Ref{Cptr{cSecurityKdata}}(C_NULL)
    symbol_list = join(symbols, ",")
    sym = Libc.Libdl.dlsym(lib, :get_security_kdata)
    err = ccall(sym, Int32, (Ptr{UInt8}, Ptr{UInt8}, Ptr{UInt8}, Ptr{UInt8}, Ptr{UInt8}, Cptr{Cptr{cSecurityKdata}}, Ptr{Cint}), symbol_list, begin_time, end_time, frequency, fq, std, len)
    if err == 0
        res = cSecurityKdata[]
        for i = 1:len.x
            stdi = unsafe_load(std[] + i - 1)
            push!(res, stdi)
        end
        return res
    else
        return cSecurityKdata[]
    end
end
export get_security_kdata


"""
    get_last_security_nkdata(symbols::Vector{String}, n::Integer, frequency::String, fq::String)::Vector{cSecurityKdata}
 * 获取当日当前时刻前最新的N笔K线数据,
 * 支持任意分钟或天的K线数据获取，
 * 同时支持单个代码或多个代码组合的数据获取。
 *
 * @param  symbol_list 证券代码列表，以逗号分开的市场.证券代码，如"sh.601211,sz.000001"
 * @param  n           请求的数据条数
 * @param  skd         获取的K线数据
 * @param  count       获取的K线数据个数
 * @param  frequency   计算频率，只能为"1min"和"1day",默认为"1min"
 * @param  fq          复权方式（前复权:"before"、不复权:"none"，默认为"none"）
 * @return             返回Vector{cSecurityKdata}
"""
function get_last_security_nkdata(symbols::Vector{String}, n::Integer, frequency::String, fq::String)::Vector{cSecurityKdata}
    len = Ref{Cint}()
    std = Ref{Cptr{cSecurityKdata}}(C_NULL)
    symbol_list = join(symbols, ",")
    sym = Libc.Libdl.dlsym(lib, :get_last_security_nkdata)
    err = ccall(sym, Int32, (Ptr{UInt8}, Cint, Cptr{Cptr{cSecurityKdata}}, Ptr{Cint}, Ptr{UInt8}, Ptr{UInt8}), symbol_list, n, std, len, frequency, fq)
    if err == 0
        res = cSecurityKdata[]
        for i = 1:len.x
            stdi = unsafe_load(std[] + i - 1)
            push!(res, stdi)
        end
        return res
    else
        return cSecurityKdata[]
    end
end
export get_last_security_nkdata

"""
    get_codelist(codetab::String, begin_date::String, end_date::String, onlycode::Bool)::Vector{cCodeInfo}
 * 获取某个时间段内的代码表信息，包含各种股票列表、基金列表、指数列表、债券列表、期货列表和期权列表
 *
 * @param  codetab     代码表名，比如"HS300"
 * @param  ci          获取的代码信息数据
 * @param  count       获取的代码信息数据个数
 * @param  begin_date  开始日期，比如"2017/1/3",不能为空
 * @param  end_date    结束日期，比如"2017/2/1",不能为空
 * @param  onlycode    是否只需要代码，默认为true，表示只需要代码
 * @return             返回Vector{cCodeInfo}
"""
function get_codelist(codetab::String, begin_date::String, end_date::String, onlycode::Bool)::Vector{cCodeInfo}
    len = Ref{Cint}()
    std = Ref{Cptr{cCodeInfo}}(C_NULL)
    sym = Libc.Libdl.dlsym(lib, :get_codelist)
    err = ccall(sym, Int32, (Ptr{UInt8}, Cptr{Cptr{cCodeInfo}}, Ptr{Cint}, Ptr{UInt8}, Ptr{UInt8}, Cint), codetab, std, len, begin_date, end_date, onlycode)
    if err == 0
        res = cCodeInfo[]
        for i = 1:len.x
            stdi = unsafe_load(std[] + i - 1)
            push!(res, stdi)
        end
        return res
    else
        return cCodeInfo[]
    end
end
export get_codelist

"""
    get_codeinfo(code::String, date::String)::cCodeInfo
* 获取某天的某个代码信息，包含各种股票、期货和期权
*
* @param  code         代码名,形如"市场.代码",比如"SH.600000"
* @param  date         指定的日期，比如"2017/1/3",默认为NULL,表示当天
*
* @return ci           返回获取的代码信息数据
"""
function get_codeinfo(code::String, date::String)::cCodeInfo
    std = Ref{Cptr{cCodeInfo}}(C_NULL)
    sym = Libc.Libdl.dlsym(lib, :get_codeinfo)
    err = ccall(sym, Int32, (Ptr{UInt8}, Cptr{Cptr{cCodeInfo}}, Ptr{UInt8}), code, std, date)
    println(err)
    if err == 0
        res = unsafe_load(std[])
        return res
    else
        return cCodeInfo()
    end
end
export get_codeinfo

"""
    get_codeinfo(code::String)::cCodeInfo
* 获取当天的某个代码信息，包含各种股票、期货和期权
*
* @param  code         代码名,形如"市场.代码",比如"SH.600000"
*
* @return ci           返回获取的代码信息数据
"""
function get_codeinfo(code::String)::cCodeInfo
    std = Ref{Cptr{cCodeInfo}}(C_NULL)
    sym = Libc.Libdl.dlsym(lib, :get_codeinfo)
    err = ccall(sym, Int32, (Ptr{UInt8}, Cptr{Cptr{cCodeInfo}}, Ptr{UInt8}), code, std, C_NULL)
    println(err)
    if err == 0
        res = unsafe_load(std[])
        return res
    else
        return cCodeInfo()
    end
end
export get_codeinfo

"""
    get_tradedate(market::String, begin_date::String, end_date::String)::Vector{Int}
 * 获取某个市场某段时间的交易日期数据
 *
 * @param  market      交易所代码,比如"SH"
 * @param  begin_date  开始日期，比如"2018/2/5"
 * @param  end_date    结束日期，比如"2018/2/10"
 * @param  td          获取的市场交易日期数据
 * @param  count       获取的市场交易日期数据个数
 * @return             返回交易日期的数组Vector{Int}
"""
function get_tradedate(market::String, begin_date::String, end_date::String)::Vector{Int}
    td = Ref{Cptr{cTradeDate}}(C_NULL)
    len_r = Ref{Cint}()
    sym = Libc.Libdl.dlsym(lib, :get_tradedate)
    err = ccall(sym, Int32, (Ptr{UInt8}, Ptr{UInt8}, Ptr{UInt8}, Ref{Cptr{cTradeDate}}, Ptr{Cint}), market, begin_date, end_date, td, len_r)
    if err == 0
        tds = Int[]
        for i = 1:len_r.x
            tdi = unsafe_load(td[] + i -1)
            push!(tds, Int(tdi.date))
        end
        return tds
    else
        return Int[]
    end
end
export get_tradedate

"""
    get_qxdata(symbol::String, begin_date::String, end_date::String)::Vector{cQxData}
 * 获取某种标的的某段时间的权息数据
 *
 * @param  symbol     证券代码，带交易所代码，如"SH.600000"
 * @param  begin_date 查询开始日期，如"2017/1/3"
 * @param  end_date   查询结束日期，如"2017/10/20"
 * @param  qd         获取的权息数据数组
 * @param  count      获取的权息数据个数
 * @return            返回Vector{cQxData}
"""
function get_qxdata(symbol::String, begin_date::String, end_date::String)::Vector{cQxData}
    td = Ref{Cptr{cQxData}}(C_NULL)
    len_r = Ref{Cint}()
    sym = Libc.Libdl.dlsym(lib, :get_qxdata)
    err = ccall(sym, Int32, (Ptr{UInt8}, Ptr{UInt8}, Ptr{UInt8}, Ref{Cptr{cQxData}}, Ptr{Cint}), symbol, begin_date, end_date, td, len_r)
    if err == 0
        tds = cQxData[]
        for i = 1:len_r.x
            tdi = unsafe_load(td[] + i -1)
            push!(tds, tdi)
        end
        return tds
    else
        return cQxData[]
    end
end
export get_qxdata

#/************************ 获取历史行情相关接口 End ***************************/

#/************************ 订阅实时行情相关接口 Begin ***********************/

"""
    md_subscribe(symbols::Vector{String})::Int32
 * 订阅代码列表的行情。
 *
 * @param  symbol_list 订阅串有三节组成, 分别对应
 *                     交易所.代码.数据类型
 *                     现在K线只支持1分钟K线订阅
 *                     比如"SH.601211.tick,SZ.000002.bar,SH.000001.index,
 *                          SZ.000001.zw,SZ.000001.zc,SZ.000001.fast,SZ.000001.queue"
 *
 * @return             成功返回0，失败返回错误码
"""
function md_subscribe(symbols::Vector{String})::Int32
    symbol_list = join(symbols,",")
    sym = Libc.Libdl.dlsym(lib, :md_subscribe)
    err = ccall(sym, Int32, (Ptr{UInt8}, ), symbol_list)
    return err
end
export md_subscribe

"""
    md_unsubscribe(symbols::Vector{String})::Int32
 * 退订指定代码表的行情。
 *
 * @param  symbol_list 证券代码或交易所代码，其中证券代码包括市场，
 *                     代码和行情数据类型
 *                     比如"SH.601211.tick,SZ.000002.bar,SH.000001.index,
 *                          SZ.000001.zw,SZ.000001.zc,SZ.000001.fast,SZ.000001.queue"
 * @return             成功返回0，失败返回错误码
"""
function md_unsubscribe(symbols::Vector{String})::Int32
    symbol_list = join(symbols,",")
    sym = Libc.Libdl.dlsym(lib, :md_unsubscribe)
    err = ccall(sym, Int32, (Ptr{UInt8}, ), symbol_list)
    return err
end
export md_unsubscribe

"""
    md_unsubscribeall()::Int32
 * 退订之前订阅的所有行情。
 *
 * @return             成功返回0，失败返回错误码
"""
function md_unsubscribeall()::Int32
    sym = Libc.Libdl.dlsym(lib, :md_unsubscribeall)
    err = ccall(sym, Int32, ())
    return err
end
export md_unsubscribeall

"""
    md_set_security_tick_callback(on_security_tick::Function, user_data::Ptr{Cvoid}=C_NULL)::Int32
 * 设置证券tick级数据行情事件回调方法
 *
 * @param on_security_tick    收到证券tick行情时调用设置的回调方法
 * @param user_data           用户自定义参数，与回调相关的任意类型数据，作为回调函数参数输入
"""
function md_set_security_tick_callback(on_security_tick_c::Ptr{Nothing}, user_data::Ptr{Cvoid}=C_NULL)::Int32
    sym = Libc.Libdl.dlsym(lib, :md_set_security_tick_callback)
    ccall(sym, Int32, (Ptr{Cvoid}, Ptr{Cvoid}), on_security_tick_c, user_data)
end
export md_set_security_tick_callback

"""
    md_set_index_tick_callback(on_index_tick::Function, user_data::Ptr{Cvoid}=C_NULL)::Int32
 * 设置指数tick级数据行情事件回调方法
 *
 * @param on_index_tick  收到指数tick行情时调用设置的回调方法
 * @param user_data      用户自定义参数，与回调相关的任意类型数据，
 *                       作为回调函数参数输入
"""
function md_set_index_tick_callback(on_index_tick_c::Ptr{Nothing}, user_data::Ptr{Cvoid}=C_NULL)::Int32
    sym = Libc.Libdl.dlsym(lib, :md_set_index_tick_callback)
    ccall(sym, Int32, (Ptr{Cvoid}, Ptr{Cvoid}), on_index_tick_c, user_data)
end 
export md_set_index_tick_callback

"""
    md_set_futures_tick_callback(on_futures_tick::Function, user_data::Ptr{Cvoid}=C_NULL)::Int32
 * 设置期货tick级数据行情事件回调方法
 *
 * @param on_futures_tick  收到期货tick行情时调用设置的回调方法
 * @param user_data        用户自定义参数，与回调相关的任意类型数据，
 *                         作为回调函数参数输入
"""
function md_set_futures_tick_callback(on_futures_tick_c::Ptr{Nothing}, user_data::Ptr{Cvoid}=C_NULL)::Int32
    sym = Libc.Libdl.dlsym(lib, :md_set_futures_tick_callback)
    ccall(sym, Int32, (Ptr{Cvoid}, Ptr{Cvoid}), on_futures_tick_c, user_data)
end
export md_set_futures_tick_callback

"""
    md_set_options_tick_callback(on_options_tick::Function, user_data::Ptr{Cvoid}=C_NULL)::Int32
 * 设置期权tick级数据行情事件回调方法
 *
 * @param on_options_tick   收到期权tick行情时调用设置的回调方法
 * @param user_data         用户自定义参数，与回调相关的任意类型数据，
 *                          作为回调函数参数输入
"""
function md_set_options_tick_callback(on_options_tick_c::Ptr{Nothing}, user_data::Ptr{Cvoid}=C_NULL)::Int32
    sym = Libc.Libdl.dlsym(lib, :md_set_options_tick_callback)
    ccall(sym, Int32, (Ptr{Cvoid}, Ptr{Cvoid}), on_options_tick_c, user_data)
end
export md_set_options_tick_callback

"""
   md_set_tickbytick_callback(on_t2t_tick::Function, user_data::Ptr{Cvoid}=C_NULL)::Int32 
 * @brief 设置逐笔数据行情事件回调方法
 *
 * @param on_t2t_tick    收到逐笔行情时调用设置的回调方法
 * @param user_data      用户自定义参数，与回调相关的任意类型数据，
 *                       作为回调函数参数输入
"""
function md_set_tickbytick_callback(on_t2t_tick_c::Ptr{Nothing}, user_data::Ptr{Cvoid}=C_NULL)::Int32
    sym = Libc.Libdl.dlsym(lib, :md_set_tickbytick_callback)
    ccall(sym, Int32, (Ptr{Cvoid}, Ptr{Cvoid}), on_t2t_tick_c, user_data)
end
export md_set_tickbytick_callback

"""
    md_set_security_kdata_callback(on_bar::Function, user_data::Ptr{Cvoid}=C_NULL)::Int32
 * 设置证券K线数据行情事件回调方法
 *
 * @param on_bar         证券K线回调方法
 * @param user_data      用户自定义参数，与回调相关的任意类型数据，作为回调函数参数输入
"""
function md_set_security_kdata_callback(on_bar_c::Ptr{Nothing}, user_data::Ptr{Cvoid}=C_NULL)::Int32
    sym = Libc.Libdl.dlsym(lib, :md_set_security_kdata_callback)
    ccall(sym, Int32, (Ptr{Cvoid}, Ptr{Cvoid}), on_bar_c, user_data)
end
export md_set_security_kdata_callback

"""
    md_set_orderqueue_callback(on_order_queue::Function, user_data::Ptr{Cvoid}=C_NULL)::Int32
* @brief 设置委托队列数据消息包回调方法
*
* @param on_order_queue       委托队列数据回调方法
* @param user_data            用户自定义参数，与回调相关的任意类型数据，作为回调函数参数输入
"""
function md_set_orderqueue_callback(on_order_queue_c::Ptr{Nothing}, user_data::Ptr{Cvoid}=C_NULL)::Int32
    sym = Libc.Libdl.dlsym(lib, :md_set_orderqueue_callback)
    ccall(sym, Int32, (Ptr{Cvoid}, Ptr{Cvoid}), on_order_queue_c, user_data)
end
export  md_set_orderqueue_callback

"""
    md_set_date_update_callback(on_date_update::Function, user_data::Ptr{Cvoid}=C_NULL)::Int32
* 设置市场日期更新行情事件回调方法
*
* @param on_date_update    市场日期更新回调方法
* @param user_data         用户自定义参数，与回调相关的任意类型数据，作为回调函数参数输入
"""
function md_set_date_update_callback(on_date_update_c::Ptr{Nothing}, user_data::Ptr{Cvoid}=C_NULL)::Int32
    sym = Libc.Libdl.dlsym(lib, :md_set_date_update_callback)
    ccall(sym, Int32, (Ptr{Cvoid}, Ptr{Cvoid}), on_date_update_c, user_data)
end
export  md_set_date_update_callback

"""
    md_set_status_change_callback(on_md_status_change::Function, user_data::Ptr{Cvoid}=C_NULL)::Int32
 * 设置行情连接状态的改变事件回调方法，目前支持"连接断开或失败"：0、"连接成功"：1
 *
 * @param on_md_status_change     行情连接状态改变回调函数
 * @param user_data               用户自定义参数，与回调相关的任意类型数据，
 *                                作为回调函数参数输入
"""
function md_set_status_change_callback(on_md_status_change_c::Ptr{Nothing}, user_data::Ptr{Cvoid}=C_NULL)::Int32
    sym = Libc.Libdl.dlsym(lib, :md_set_status_change_callback)
    ccall(sym, Int32, (Ptr{Cvoid}, Ptr{Cvoid}), on_md_status_change_c, user_data)
end
export  md_set_status_change_callback
#/************************ 订阅实时行情相关接口 end ***********************/
###########################################trade_api###############################################
export cOrderReq    
export cCancelDetail
export cCancelReq   
export cOrderRsp    
export cOrder       
export cTrade       
export cPosition    
export cCash        
export cIndicator   

"""
    td_order(account_id::String, account_type::Integer, orders::Vector{cOrderReq}, async::Integer=1)::Cint
 * 批量下单，同步异步使用一个接口
 *
 * @param account_id    资金账户id
 * @param account_type  资金账户类型，见AccountType定义
 * @param orders        传入委托请求对象数组，返回后台系统生成的内部订单id
 * @param async         是否异步，0：同步下单，非0(默认)：异步下单(需在OrderReq明细中返回order_id)
 *
 * @return              成功返回0，失败返回错误码，错误码定义在error.h文件中
"""
function td_order(account_id::String, account_type::Integer, orders::Vector{cOrderReq}, async::Integer=1)::Cint
    len = length(orders)
    sym = Libc.Libdl.dlsym(lib, :td_order)
    err = ccall(sym, Int32, (Ptr{UInt8}, Cint, Cptr{cOrderReq}, Cint, Cint), account_id, account_type, orders, len, async)
end
export td_order

"""
    td_reverse_repurchase(account_id::String, account_type::Integer, price::Integer, volume::Integer, cl_order_id::String="", len::Integer=256)::String
 * 逆回购下单，同步异步使用一个接口
 *
 * @param account_id    资金账户id
 * @param account_type  资金账户类型，见AccountType定义
 * @param symbol        标的代码，例如SH.204001, SZ.131810，目前仅支持1天期
 * @param price         委托价，逆回购为利率扩大1万倍
 * @param volume        委托量，单位为张，上海单笔最少1000张或是其整数倍，深圳单笔最少10张或是其整数倍
 * @param length        传入的order_id内存长度
 * @param cl_order_id   NULL为同步下单，非NULL值为异步下单
 *
 * @return order_id      输出参数，同步下单立即返回后台系统生成的内部订单id，异步下单返回为空
"""
function td_reverse_repurchase(account_id::String, account_type::Integer, price::Integer, volume::Integer, cl_order_id::String="", len::Integer=256)::String
    order_id = Vector{UInt8}(undef,len)
    sym = Libc.Libdl.dlsym(lib, :td_reverse_repurchase)
    if length(cl_order_id) == 0
        err = ccall(sym, Int32, (Ptr{UInt8}, Cint, Ptr{UInt8}, UInt64, Cint, Ptr{UInt8}, Cint, Ptr{UInt8}), account_id, account_type, symbol, price, volume, order_id, len, C_NULL)
        if err == 0
            return unsafe_string(pointer(order_id))
        else
            return ""
        end
    else
        err = ccall(sym, Int32, (Ptr{UInt8}, Cint, Ptr{UInt8}, UInt64, Cint, Ptr{UInt8}, Cint, Ptr{UInt8}), account_id, account_type, symbol, price, volume, order_id, len, cl_order_id)
        return ""
    end
end
export td_reverse_repurchase

"""
    td_cancel_order(account_id::String, account_type::Integer, order_ids::Vector{String}, is_async::Bool=true)::Vector{cCancelDetail}
 * 批量撤单，支持撤销单个和多个订单，同步异步使用一个接口
 *
 * @param account_id    资金账户id
 * @param account_type  资金账户类型，见AccountType定义
 * @param order_ids     传入系统返回的订单id，格式为order1,order2,order3
 * @param is_async      true：异步撤单； false: 同步撤单
 *
 * @return cancel_list  返回撤单详情列表(异步撤单时返回空)
"""
function td_cancel_order(account_id::String, account_type::Integer, order_ids::Vector{String}, is_async::Bool=true)::Vector{cCancelDetail}
    orders = join(order_ids, ",")
    cancel_list = cCancelDetail[]
    sym = Libc.Libdl.dlsym(lib, :td_cancel_order)
    if is_async
        err = ccall(sym, Int32, (Ptr{UInt8}, Cint, Ptr{UInt8}, Cptr{Cptr{cCancelDetail}}, Ptr{Cint}), account_id, account_type, orders, C_NULL, C_NULL)
    else
        len_r = Ref{Cint}(0)
        cancel_list_r = Ref{Cptr{cCancelDetail}}(C_NULL)
        err = ccall(sym, Int32, (Ptr{UInt8}, Cint, Ptr{UInt8}, Cptr{Cptr{cCancelDetail}}, Ptr{Cint}), account_id, account_type, orders, cancel_list_r, len_r)
        if err == 0
            for i = 1:len_r.x
                cancel = unsafe_load(cancel_list_r[] + i - 1)
                push!(cancel_list, cancel)
            end
        end
    end
    return cancel_list
end
export td_cancel_order



"""
 * 撤销全部未完成订单，同步异步使用一个接口
 *
 * @param account_id    资金账户id
 * @param account_type  资金账户类型，见AccountType定义
 * @param trade_seqno   交易序号，即批次号。给0撤全部，给非0值撤指定批次
 * @param is_async      true：异步撤单； false: 同步撤单
 *
 * @return cancel_list  返回撤单详情列表(异步撤单时返回空)
"""
function td_cancel_all_order(account_id::String, account_type::Integer; trade_seqno::Integer=0, is_async::Bool=true)::Vector{cCancelDetail}
    cancel_list = cCancelDetail[]
    sym = Libc.Libdl.dlsym(lib, :td_cancel_all_order)
    if is_async
        err = ccall(sym, Int32, (Ptr{UInt8}, Cint, Cint, Cptr{Cptr{cCancelDetail}}, Ptr{Cint}), account_id, account_type, trade_seqno, C_NULL, C_NULL)
    else
        len_r = Ref{Cint}(0)
        cancel_list_r = Ref{Cptr{cCancelDetail}}(C_NULL)
        err = ccall(sym, Int32, (Ptr{UInt8}, Cint, Cint, Cptr{Cptr{cCancelDetail}}, Ptr{Cint}), account_id, account_type, trade_seqno, cancel_list_r, len_r)
        if err == 0
            for i = 1:len_r.x
                cancel = unsafe_load(cancel_list_r[] + i - 1)
                push!(cancel_list, cancel)
            end
        end
    end
    return cancel_list
end    
export td_cancel_all_order

"""
    td_get_order(order_id::String)::Union{cOrder,Nothing}
 * 查订单详情
 *
 * @param order_id      后台生成的订单id
 *
 * @return ret_order     返回对应订单详情
"""
function td_get_order(order_id::String)
    ret_order = Ref{cOrder}()
    sym = Libc.Libdl.dlsym(lib, :td_get_order)
    err = ccall(sym, Int32, (Ptr{UInt8}, Cptr{cOrder}), order_id, ret_order)
    if err == 0
        return ret_order[]
    else
        return nothing
    end
end
export td_get_order

"""
    td_get_orders(page_num::Integer, page_size::Integer, begin_date::String="", end_date::String="")::Vector{cOrder}
/**
 * 查策略实例订单列表，支持分页查询
 *
 * @param page_num      page_num表示此次分页请求从哪一页开始，第一页page_num为1
 * @param page_size     输入时：分页个数，输出时：实际返回的订单个数
 *                      ***注意：返回个数小于输入的分页个数时，表示数据已经全部读取完毕***
 * @param begin_date    查询开始日期，如果为空或NULL，则为当前交易日，格式为2018/3/1
 * @param end_date      查询结束日期，如果为空或NULL，则为当前交易日，格式为2018/3/1
 *                      end_date必须大于等于begin_date，可以只传begin_date，不可以只传end_date
 *
 * @return ret_orders   返回对应订单对象数组
 */
"""
function td_get_orders(page_num::Integer, page_size::Integer; begin_date::String="", end_date::String="")::Vector{cOrder}
    page_r = Ref{Cint}(page_size)
    ret_orders = Ref{Cptr{cOrder}}(C_NULL)
    if length(begin_date) == 0
        begin_date = C_NULL
    end
    if length(end_date) == 0
        end_date = C_NULL
    end
    println("ret_orders:", ret_orders)
    sym = Libc.Libdl.dlsym(lib, :td_get_orders)
    err = ccall(sym, Int32, (Cint, Ptr{Cint}, Cptr{Cptr{cOrder}}, Ptr{Cint}, Ptr{UInt8}, Ptr{UInt8}), page_num, page_r, ret_orders, C_NULL, begin_date, end_date)
    if err == 0
        println("ret_orders:", ret_orders)
        println("page_num:", page_r[])
        orders_p = [ret_orders[] + i - 1 for i in 1:page_r[]]
        orders = unsafe_load.(orders_p)
    else
        orders = cOrder[]
    end
    return orders
end

"""
    td_get_orders(begin_date::String="", end_date::String="", page_size::Integer=100)::Vector{cOrder}
 * 查策略实例订单列表
 *
 * @param begin_date    查询开始日期，如果为空或NULL，则为当前交易日，格式为2018/3/1
 * @param end_date      查询结束日期，如果为空或NULL，则为当前交易日，格式为2018/3/1
 *                      end_date必须大于等于begin_date，可以只传begin_date，不可以只传end_date
 * @param page_size     内部分页查询时，一次返回的订单条数
 *
 * @return ret_orders   返回对应订单对象数组
"""
function td_get_orders(;begin_date::String="", end_date::String="",page_size::Integer=100)::Vector{cOrder}
    lenorders = page_size
    orders = cOrder[]
    page_num = 1
    while lenorders == page_size
        ordersi = td_get_orders(page_num, page_size, begin_date=begin_date, end_date=end_date)
        lenorders = length(ordersi)
        push!(orders, ordersi...)
        page_num += 1
    end
    return orders
end
export td_get_orders

"""
    td_get_open_orders(page_num::Integer, page_size::Integer, date::String="")::Vector{cOrder}
 * 查未完成订单列表，支持分页查询
 *
 * @param page_num      page_num表示此次分页请求从哪一页开始，第一页page_num为1
 * @param page_size     输入时：分页个数，输出时：实际返回的订单个数
 *                      ***注意：返回个数小于输入的分页个数时，表示数据已经全部读取完毕***
 * @param date          查询日期,如果为空或NULL，则为当前交易日，格式为2018/3/1
 *
 * @return ret_orders   返回对应订单对象数组
"""
function td_get_open_orders(page_num::Integer, page_size::Integer, date::String="")::Vector{cOrder}
    page_r = Ref{Cint}(page_size)
    ret_orders = Ref{Cptr{cOrder}}(C_NULL)
    if length(date) == 0
        date = C_NULL
    end
    println("ret_orders:", ret_orders)
    sym = Libc.Libdl.dlsym(lib, :td_get_open_orders)
    err = ccall(sym, Int32, (Cint, Ptr{Cint}, Cptr{Cptr{cOrder}}, Ptr{Cint}, Ptr{UInt8}), page_num, page_r, ret_orders, C_NULL, date)
    if err == 0
        println("ret_orders:", ret_orders)
        println("page_size:", page_r[])
        orders_p = [ret_orders[] + i - 1 for i in 1:page_r.x]
        orders = unsafe_load.(orders_p)
    else
        orders = cOrder[]
    end
    return orders
end

"""
    td_get_open_orders(date::String="" ,page_size::Integer=100)::Vector{cOrder}
 * 查未完成订单列表

 * @param date          查询日期,如果为空或NULL，则为当前交易日，格式为2018/3/1
 * @param page_size     内部分页查询时，一次返回的订单条数
 *
 * @return ret_orders   返回对应订单对象数组
"""
function td_get_open_orders(;date::String="" ,page_size::Integer=100)::Vector{cOrder}
    lenorders = page_size
    orders = cOrder[]
    page_num = 1
    while lenorders == page_size
        ordersi = td_get_open_orders(page_num, page_size, date)
        lenorders = length(ordersi)
        push!(orders, ordersi...)
        page_num += 1
    end
    return orders
end
export td_get_open_orders

"""
    td_get_trades(order_id::String)::Vector{cTrade}
 * 查单个订单成交列表
 *
 * @param order_id      后台系统生成的订单id
 
 * @return ret_trades   返回对应成交列表
"""
function td_get_trades(order_id::String)::Vector{cTrade}
    ret_trades = Ref{Cptr{cTrade}}(C_NULL)
    ret_count = Ref{Cint}(0)
    sym = Libc.Libdl.dlsym(lib, :td_get_trades)
    err = ccall(sym, Int32, (Ptr{UInt8}, Cptr{Cptr{cTrade}}, Ptr{Cint}), order_id, ret_trades, ret_count)
    trades = cTrade[]
    if err == 0
        for i = 1:ret_count.x
            tradei = unsafe_load(ret_trades[] + i - 1)
            push!(trades, tradei)
        end
    end
    return trades
end
export td_get_trades


"""
    td_get_strategy_trades(page_num::Integer, page_size::Integer, begin_date::String="", end_date::String="")::Vector{cTrade}
 * 查策略实例成交列表，分页查询
 *
 * @param page_num      page_num表示此次分页请求从哪一页开始，第一页page_num为1
 * @param page_size     输入时：分页个数，输出时：实际返回的成交个数
 *                      ***注意：返回个数小于输入的分页个数时，表示数据已经全部读取完毕***
 * @param begin_date    查询开始日期,如果为空或NULL，则为当前交易日，格式为2018/3/1
 * @param end_date      查询结束日期,如果为空或NULL，则为当前交易日，格式为2018/3/1
 *                      end_date必须大于等于begin_date，可以只传begin_date，不可以只传end_date
 *
 * @return ret_trades   返回对应成交列表
"""
function td_get_strategy_trades(page_num::Integer, page_size::Integer; begin_date::String="", end_date::String="")::Vector{cTrade}
    page_r = Ref{Cint}(page_size)
    ret_trades = Ref{Cptr{cTrade}}(C_NULL)
    if length(begin_date) == 0
        begin_date = C_NULL
    end
    if length(end_date) == 0
        end_date = C_NULL
    end
    sym = Libc.Libdl.dlsym(lib, :td_get_strategy_trades)
    err = ccall(sym, Int32, (Cint, Ptr{Cint}, Cptr{Cptr{cTrade}}, Ptr{Cint}, Ptr{UInt8}, Ptr{UInt8}), page_num, page_r, ret_trades, C_NULL, begin_date, end_date)
    if err == 0
        trades_p = [ret_trades[] + i - 1 for i in 1:page_r.x]
        trades = unsafe_load.(trades_p)
    else
        trades = cTrade[]
    end
    return trades
end

"""
    td_get_strategy_trades(begin_date::String="", end_date::String="", page_size::Integer=100)::Vector{cTrade}
 * 查策略实例成交列表
 *
 * @param begin_date    查询开始日期,如果为空或NULL，则为当前交易日，格式为2018/3/1
 * @param end_date      查询结束日期,如果为空或NULL，则为当前交易日，格式为2018/3/1
 *                      end_date必须大于等于begin_date，可以只传begin_date，不可以只传end_date
 * @param page_size     内部分页查询时，一次返回的成交条数
 *
 * @return ret_trades   返回对应成交列表
"""
function td_get_strategy_trades(;begin_date::String="", end_date::String="", page_size::Integer=100)::Vector{cTrade}
    lentrades = page_size
    trades = cTrade[]
    page_num = 1
    while lentrades == page_size
        tradesi = td_get_strategy_trades(page_num, page_size, begin_date = begin_date, end_date = end_date)
        lentrades = length(tradesi)
        push!(trades, tradesi...)
        page_num += 1
    end
    return trades
end

"""
    td_get_position(symbol::String, account_id::String, account_type::Integer)::Vector{cPosition}
 * 查策略实例指定标的持仓，可返回指定资金账号的对应标的持仓
 *
 * @param symbol        标的代码，例如SH.600000, CFFEX.IF1511
 * @param ret_positions 返回对应持仓列表
 * @param count         返回的仓位个数
 * @param account_id    资金账户id，返回指定资金账号指定标的持仓
 * @param account_type  资金账户类型，见AccountType定义
 *
 * @return              成功返回0，失败返回错误码，错误码定义在error.h文件中
"""
function td_get_position(symbol::String, account_id::String, account_type::Integer)::Vector{cPosition}
    ret_positions = Ref{Cptr{cPosition}}(C_NULL)
    ret_count = Ref{Cint}(0)
    sym = Libc.Libdl.dlsym(lib, :td_get_position)
    err = ccall(sym, Int32, (Ptr{UInt8}, Cptr{Cptr{cPosition}}, Ptr{Cint}, Ptr{UInt8}, Cint), symbol, ret_positions, ret_count, account_id, account_type)
    positions = cPosition[]
    if err == 0
        for i = 1:ret_count.x
            positioni = unsafe_load(ret_positions[] + i - 1)
            push!(positions, positioni)
        end
    end
    return positions
end
export td_get_position
    

"""
    td_get_positions(page_num::Integer, page_size::Integer, begin_date::String="", end_date::String="")::Vector{cPosition}
 * 查策略实例持仓列表，分页查询
 *
 * @param page_num      page_num表示此次分页请求从哪一页开始，第一页page_num为1
 * @param page_size     输入时：分页个数，输出时：实际返回的仓位个数
 *                      ***注意：返回个数小于输入的分页个数时，表示数据已经全部读取完毕***
 * @param begin_date    查询开始日期,如果为空或NULL，则为当前交易日，格式为2018/3/1
 * @param end_date      查询结束日期,如果为空或NULL，则为当前交易日，格式为2018/3/1
 *                      end_date必须大于等于begin_date，可以只传begin_date，不可以只传end_date
 *
 * @return ret_positions  返回对应持仓列表
"""
function td_get_positions(page_num::Integer, page_size::Integer; begin_date::String="", end_date::String="")::Vector{cPosition}
    page_r = Ref{Cint}(page_size)
    ret_positions = Ref{Cptr{cPosition}}(C_NULL)
    if length(begin_date) == 0
        begin_date = C_NULL
    end
    if length(end_date) == 0
        end_date = C_NULL
    end
    sym = Libc.Libdl.dlsym(lib, :td_get_positions)
    err = ccall(sym, Int32, (Cint, Ptr{Cint}, Cptr{Cptr{cPosition}}, Ptr{Cint}, Ptr{UInt8}, Ptr{UInt8}), page_num, page_r, ret_positions, C_NULL, begin_date, end_date)
    if err == 0
        positions_p = [ret_positions[] + i - 1 for i in 1:page_r.x]
        positions = unsafe_load.(positions_p)
    else
        positions = cPosition[]
    end
    return positions
end

"""
    td_get_positions(;begin_date::String="", end_date::String="", page_size::Integer=100)::Vector{cPosition}
 * 查策略实例持仓列表
 *
 * @param begin_date    查询开始日期,如果为空或NULL，则为当前交易日，格式为2018/3/1
 * @param end_date      查询结束日期,如果为空或NULL，则为当前交易日，格式为2018/3/1
 *                      end_date必须大于等于begin_date，可以只传begin_date，不可以只传end_date
 * @param page_size     内部分页查询时，一次返回的仓位个数
 *
 * @return ret_positions  返回对应持仓列表
"""
function td_get_positions(;begin_date::String="", end_date::String="", page_size::Integer=100)::Vector{cPosition}
    lenpositions = page_size
    positions = cPosition[]
    page_num = 1
    while lenpositions == page_size
        positionsi = td_get_positions(page_num, page_size, begin_date = begin_date, end_date = end_date)
        lenpositions = length(positionsi)
        push!(positions, positionsi...)
        page_num += 1
    end
    return positions
end

"""
    td_get_cash()::Vector{cCash}
 * 查策略实例所有资金账户的资金数据
 *
 * @return ret_cash      返回策略实例资金账户数据列表
"""
function td_get_cash()::Vector{cCash}
    ret_cash = Ref{Cptr{cCash}}(C_NULL)
    ret_count = Ref{Cint}(0)
    sym = Libc.Libdl.dlsym(lib, :td_get_cash)
    err = ccall(sym, Int32, (Cptr{Cptr{cCash}}, Ptr{Cint}), ret_cash, ret_count)
    cash_vector = cCash[]
    if err == 0
        for i = 1:ret_count.x
            cashi = unsafe_load(ret_cash[] + i - 1)
            push!(cash_vector, cashi)
        end
    end
    return cash_vector
end
export td_get_cash

"""
    td_get_counter_positions(account_id::String, account_type::Integer, page_num::Integer, page_size::Integer)::Vector{cPosition}
 * 查策略柜台持仓，支持分页查询
 * @param account_id    资金账户id
 * @param account_type  资金账户类型，见AccountType定义
 * @param page_num      page_num表示此次分页请求从哪一页开始，第一页page_num为1
 * @param page_size     输入时：分页个数，输出时：实际返回的仓位个数
 *                      ***注意：返回个数小于输入的分页个数时，表示数据已经全部读取完毕***
 *
 * @return positions    返回对应持仓列表, 失败返回空
"""
function td_get_counter_positions(account_id::String, account_type::Integer, page_num::Integer, page_size::Integer)::Vector{cPosition}
    page_r = Ref{Cint}(page_size)
    ret_positions = Ref{Cptr{cPosition}}(C_NULL)
    sym = Libc.Libdl.dlsym(lib, :td_get_counter_positions)
    err = ccall(sym, Int32, (Ptr{UInt8}, Cint, Cint, Ptr{Cint}, Cptr{Cptr{cPosition}}), account_id, account_type, page_num, page_r, ret_positions)
    if err == 0
        positions_p = [ret_positions[] + i - 1 for i in 1:page_r.x]
        positions = unsafe_load.(positions_p)
    else
        positions = cPosition[]
    end
    return positions
end

"""
    td_get_counter_positions(account_id::String, account_type::Integer)::Vector{cPosition}
 * 查策略柜台持仓，支持分页查询
 * @param account_id    资金账户id
 * @param account_type  资金账户类型，见AccountType定义
 *
 * @return positions    返回对应持仓列表, 失败返回空
"""
function td_get_counter_positions(account_id::String, account_type::Integer)
    lenpositions = 100
    page_size = 100
    positions = cPosition[]
    page_num = 1
    while lenpositions == page_size
        positionsi = td_get_counter_positions(account_id, account_type, page_num, page_size)
        lenpositions = length(positionsi)
        push!(positions, positionsi...)
        page_num += 1
    end
    return positions
end

"""
    td_get_counter_cash(account_id::String, account_type::Integer)::Vector{cCash}
 * 查策略柜台资金，只会返回一个资金明细
 * @param account_id    资金账户id
 * @param account_type  资金账户类型，见AccountType定义
 *
 * @return ret_cash     返回对应账户的资金, 失败返回空
"""
function td_get_counter_cash(account_id::String, account_type::Integer)::Vector{cCash}
    ret_cash = Ref{Cptr{cCash}}(C_NULL)
    ret_count = Ref{Cint}(0)
    sym = Libc.Libdl.dlsym(lib, :td_get_counter_cash)
    err = ccall(sym, Int32, (Ptr{UInt8}, Cint, Cptr{cCash}, Ptr{Cint}), account_id, account_type, ret_cash, ret_count)
    cash_vector = cCash[]
    if err == 0
        for i = 1:ret_count[]
            cashi = unsafe_load(ret_cash[] + i - 1)
            push!(cash_vector, cashi)
        end
    end
    return cash_vector
end


"""
    td_transfer_position(account_id::String, account_type::Integer, side::Integer, symbol::String, 
                         symbol::String, volume::Integer, price::Integer)::Cint                      
 * 实例持仓划转
 * @param account_id    资金账户id
 * @param account_type  资金账户类型，见AccountType定义
 * @param side          0对应划入，1对应划出
 * @param symbol        标的代码，例如SH.600000, CFFEX.IF1511
 * @param volume        划转的数量，单位股/张
 * @param price         标的的价格，放大10000倍。用于计算持仓成本价
 *
 * @return              成功返回0，失败返回错误码，错误码定义在error.h文件中
"""
function td_transfer_position(account_id::String, account_type::Integer, side::Integer, symbol::String, volume::Integer, price::Integer)::Cint                      
    sym = Libc.Libdl.dlsym(lib, :td_transfer_position)
    err = ccall(sym, Int32, (Ptr{UInt8}, Cint, Cint, Ptr{UInt8}, Cint, Cint), account_id, account_type, side, symbol, volume, price)
end

"""
    td_transfer_position(account_id::String, account_type::Integer, side::Integer, symbols::Vector{String}, 
                         symbol::String, volume::Integer, price::Integer)::Cint                      
 * 实例持仓划转
 * @param account_id    资金账户id
 * @param account_type  资金账户类型，见AccountType定义
 * @param side          0对应划入，1对应划出
 * @param symbols       标的代码数组，例如["SH.600000", "CFFEX.IF1511"]
 * @param volume        划转的数量，单位股/张
 * @param price         标的的价格，放大10000倍。用于计算持仓成本价
 *
 * @return              成功返回0，失败返回错误码，错误码定义在error.h文件中
"""
function td_transfer_position(account_id::String, account_type::Integer, side::Integer, symbols::Vector{String}, 
                              volume::Integer, price::Integer)::Cint
    symbol = join(symbols, ",")                                
    sym = Libc.Libdl.dlsym(lib, :td_transfer_position)
    err = ccall(sym, Int32, (Ptr{UInt8}, Cint, Cint, Ptr{UInt8}, Cint, Cint), account_id, account_type, side, symbol, volume, price)
end


"""
    
 * 实例资金划转
 * @param account_id    资金账户id
 * @param account_type  资金账户类型，见AccountType定义
 * @param side          0对应划入，1对应划出
 * @param cash          划转的资金数，放大10000倍
 *
 * @return              成功返回0，失败返回错误码，错误码定义在error.h文件中
"""
function td_transfer_cash(account_id::String, account_type::Integer, side::Integer, cash::Integer)::Cint
    sym = Libc.Libdl.dlsym(lib, :td_transfer_cash)
    err = ccall(sym, Int32, (Ptr{UInt8}, Cint, Cint, Int64), account_id, account_type, side, cash)
end

"""
    td_get_indicator(date::String="")
 * 查策略实例的收益、风险等指标
 *
 * @param date           查询日期,如果为空或NULL，则为当前日期，格式为2018/3/1
 *
 * @return ret_indicator 返回策略指定日期的实例的收益、风险指标信息
"""
function td_get_indicator(date::String="")
    if length(date) == 0
        date = C_NULL
    end
    ret_indicator = Ref{cIndicator}()
    sym = Libc.Libdl.dlsym(lib, :td_get_indicator)
    err = ccall(sym, Int32, (Cptr{cIndicator}, Ptr{UInt8}), ret_indicator, date)
    if err == 0
        return ret_indicator.x
    else
        return nothing
    end
end
export td_get_indicator

"""
    td_set_trade_report_callback(on_trade::Function, user_data::Ptr{Cvoid}=C_NULL)::Cvoid
 * 设置成交回报事件回调函数
 *
 * @param on_trade      回调处理函数on_trade(trade::Ptr{cTrade}, user_data::Ptr{Cvoid})
 * @param user_data     用户自定义参数，与回调相关的任意类型数据，作为回调函数参数输入
"""
function td_set_trade_report_callback(on_trade_c::Ptr{Nothing}, user_data::Ptr{Cvoid}=C_NULL)::Cvoid
    sym = Libc.Libdl.dlsym(lib, :td_set_trade_report_callback)
    ccall(sym, Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}), on_trade_c, user_data)
end
export td_set_trade_report_callback


"""
    td_set_order_rsp_callback(on_order_rsp::Function, user_data::Ptr{Cvoid}=C_NULL)::Cvoid
 * 设置订单委托应答事件回调函数
 *
 * @param on_order_rsp      回调处理函数on_order_rsp(order_rsp::Ptr{cOrderRsp}, user_data::Ptr{Cvoid})
 * @param user_data         用户自定义参数，与回调相关的任意类型数据，作为回调函数参数输入
"""
function td_set_order_rsp_callback(on_order_rsp_c::Ptr{Nothing}, user_data::Ptr{Cvoid}=C_NULL)::Cvoid
    sym = Libc.Libdl.dlsym(lib, :td_set_order_rsp_callback)
    ccall(sym, Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}), on_order_rsp_c, user_data)
end
export td_set_order_rsp_callback

"""
    td_set_cancel_order_callback(on_cancel_order::Function, user_data::Ptr{Cvoid}=C_NULL)::Cvoid
 * 设置撤单应答事件回调函数
 *
 * @param on_cancel_order   回调处理函数on_cancel_order(cancel_detail::Ptr{cCancelDetail}, user_data::Ptr{Cvoid})
 * @param user_data         用户自定义参数，与回调相关的任意类型数据，作为回调函数参数输入
"""
function td_set_cancel_order_callback(on_cancel_order_c::Ptr{Nothing}, user_data::Ptr{Cvoid}=C_NULL)::Cvoid
    sym = Libc.Libdl.dlsym(lib, :td_set_cancel_order_callback)
    ccall(sym, Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}), on_cancel_order_c, user_data)
end
export td_set_cancel_order_callback

"""
    td_set_order_status_callback(on_order::Function, user_data::Ptr{Cvoid}=C_NULL)::Cvoid
 * 设置订单状态变化事件回调函数
 *
 * @param on_order      回调处理函数on_order(order::Ptr{cOrder}, user_data::Ptr{Cvoid})
 * @param user_data     用户自定义参数，与回调相关的任意类型数据，作为回调函数参数输入
"""
function td_set_order_status_callback(on_order_c::Ptr{Nothing}, user_data::Ptr{Cvoid}=C_NULL)::Cvoid
    sym = Libc.Libdl.dlsym(lib, :td_set_order_status_callback)
    ccall(sym, Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}), on_order_c, user_data)
end
export td_set_order_status_callback

# 期货交易执行引擎 V2
# 基于 OMS 查询驱动的执行引擎，不再自行跟踪订单状态
# 核心理念：通过查询 OrderManager Service (OMS) 来决策，而非维护本地状态
#
# 状态机设计：4 阶段 + 评估循环
#   :evaluating → 查询 OMS，决策下一步
#     → 发现反向未成交委托 → 发送撤单 → :canceling
#     → 发现反向持仓 → 发送平仓单 → :closing
#     → 无障碍 → 发送开仓单 → :opening
#     → 目标已达成 → :completed
#     → 前置条件不满足 → :failed
#   :canceling → 等待撤单结果 → :evaluating
#   :closing → 等待平仓成交 → :evaluating
#   :opening → 等待开仓成交 → :completed

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

# 执行任务结构体
mutable struct ExecutionTask
    trade_date::Int       # 交易日期(YYYYMMDD)
    task_id::String
    task_type::Symbol      # :normal 普通任务; :lock 锁仓任务
    account_id::String
    account_type::Int
    symbol::String
    target_side::String      # "long" / "short"
    volume::Int
    bid_price::Int64             # 目标价格（扩大万倍）
    ask_price::Int64             # 目标价格（扩大万倍）
    strategy_id::String
    
    phase::Symbol            # :evaluating, :canceling, :closing, :opening, :completed, :failed
    
    last_sent_cl_order_id::String           # 最近发出的 cl_order_id（防重复发单）
    last_cancel_target_ids::Vector{String}  # 最近撤单的目标 order_ids
    
    last_action_time::Int64  # 最后动作时间（毫秒时间戳）
    retry_count::Int
    max_retries::Int
    timeout_ms::Int64
    
    create_time::Int64
    error_msg::String
end

# 全局状态
const exec_active_tasks = Dict{String, ExecutionTask}()   # task_id -> ExecutionTask
const exec_symbol_tasks = Dict{String, String}()          # symbol -> task_id
const order_counter = Base.Threads.Atomic{Int}(0)

# ============================================
# 2. 工具函数
# ============================================

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
const oms_query_order = Ref{Function}()
oms_query_order[] = OrderManager.om_query_order

function set_oms_query_order(f::Function)
    global oms_query_order
    oms_query_order[] = f
end

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
    send_order!(task::ExecutionTask, symbol::String, action::Symbol, direction::String, pos=nothing)

统一的发单函数，支持开仓和平仓。

参数:
- task: 执行任务
- symbol: 合约代码
- action: :open (开仓) 或 :close (平仓)
- direction: "long" 或 "short"
  - 开仓时: "long"=开多, "short"=开空
  - 平仓时: "long"=平多, "short"=平空
- pos: 平仓时需要传入持仓信息，开仓时为 nothing

返回: Bool, true 表示发单成功
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
        order = cOrderReq(
            cl_order_id = string(task.strategy_id,",",cl_order_id),
            symbol = symbol,
            order_type = Int16(1),      # 限价单
            side = side_val,
            volume = volume,
            price = price,
            hedge_flag = Int16(1),
            ext_info = ""
        )
        orders = cOrderReq[order]
        # 调用发单接口
        err = td_order(task.account_id, task.account_type, orders, 1)
        if err != 0
            action_str = action == :open ? "开仓" : "平仓"
            task.error_msg = "$(action_str)发单失败，错误码: $err"
            strategy_log(4, "[ExecutionEngineV2] $(task.error_msg), task=$(task.task_id)")
            return false
        end
        # 记录最后发出的 cl_order_id
        task.last_sent_cl_order_id = cl_order_id
        task.last_action_time = now_ms()
        action_str = action == :open ? "开仓单" : "平仓单"
        strategy_log(2, "[ExecutionEngineV2] $(action_str)已发送: task=$(task.task_id), $order_desc, vol=$volume, price=$price, cl_order_id=$cl_order_id")
        return true
    catch e
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

const oms_query_position = Ref{Function}(OrderManager.om_query_contract_stat)

function set_oms_query_position(f::Function)
    global oms_query_position
    oms_query_position[] = f
end


"""
    evaluate!(task::ExecutionTask)

核心评估函数！查询 OMS 确定当前态势并决策。

步骤1: 如果 phase 不是 :evaluating，检查当前阶段的完成情况
步骤2: 当 phase == :evaluating 时执行决策循环
"""
function evaluate!(task::ExecutionTask)
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
    
    # 根据任务类型决策
    if task.task_type == :normal
        # 根据目标方向决策
        evaluate_for_open!(task, pos, pending_open_long, pending_open_short, 
                          pending_close_long, pending_close_short)
    elseif task.task_type == :lock
        evaluate_for_lock!(task, pos, pending_open_long, pending_open_short,
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
function evaluate_for_open!(task::ExecutionTask, pos::cContractStat,
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
function evaluate_for_lock!(task::ExecutionTask, pos::cContractStat, pending_open_long::Vector{String}, pending_open_short::Vector{String},
        pending_close_long::Vector{String}, pending_close_short::Vector{String})
        symbol = task.symbol        
    # ---- 方向参数绑定 ----
    # positive = 同向(与target_side一致), negative = 反向
    if task.target_side == "long"
        pending_open_positive = pending_open_long
        pending_open_negative = pending_open_short
        pending_close_positive = pending_close_long
        pending_close_negative = pending_close_short
        today_volume_positive = pos.today_long_volume
        today_volume_negative = pos.today_short_volume
        yesterday_volume_positive = pos.yesterday_long_volume
        yesterday_volume_negative = pos.yesterday_short_volume
        today_frozen_positive = pos.today_long_frozen
        today_frozen_negative = pos.today_short_frozen
        open_price = task.ask_price
        close_price = task.bid_price
        opposite_side = "short"
    elseif task.target_side == "short"
        pending_open_positive = pending_open_short
        pending_open_negative = pending_open_long
        pending_close_positive = pending_close_short
        pending_close_negative = pending_close_long
        today_volume_positive = pos.today_short_volume
        today_volume_negative = pos.today_long_volume
        yesterday_volume_positive = pos.yesterday_short_volume
        yesterday_volume_negative = pos.yesterday_long_volume
        today_frozen_positive = pos.today_short_frozen
        today_frozen_negative = pos.today_long_frozen
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
function evaluate_for_pending_order!(task::ExecutionTask, net_volume::Int32, pending_orders::Vector{String}, side::Symbol,
        yesterday_volume::Int32, today_frozen::Int32, open_price::Int64, close_price::Int64)
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
function evaluate_for_net_volume!(task::ExecutionTask, net_volume::Int32, side::Symbol,
        yesterday_volume::Int32, opposite_side::String)
    symbol = task.symbol
    
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
# ============================================
# 7. 任务生命周期管理
# ============================================

"""
    finalize_task!(task::ExecutionTask)

完成任务，清理全局状态。
"""
function finalize_task!(task::ExecutionTask)
    # 清理 symbol -> task_id 映射
    if haskey(exec_symbol_tasks, task.symbol)
        if exec_symbol_tasks[task.symbol] == task.task_id
            delete!(exec_symbol_tasks, task.symbol)
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
function engine_notify!(symbol::String)
    # 查找该 symbol 的活跃任务
    if !haskey(exec_symbol_tasks, symbol)
        return
    end
    
    task_id = exec_symbol_tasks[symbol]
    if !haskey(exec_active_tasks, task_id)
        # 清理残留的映射
        delete!(exec_symbol_tasks, symbol)
        return
    end
    
    task = exec_active_tasks[task_id]
    
    # 如果任务在等待阶段，切回评估阶段
    if task.phase in [:canceling, :closing, :opening]
        strategy_log(2, "[ExecutionEngineV2] 收到通知，切回评估阶段: task=$(task.task_id), phase=$(task.phase)")
        task.phase = :evaluating
    end
    
    # 执行评估
    evaluate!(task)
end

"""
    create_exec_task(symbol, target_side, volume, price, strategy_id)

创建新的执行任务。
检查 exec_symbol_tasks 互斥，如果已有同 symbol 任务则 force_cancel_task! 旧任务。
"""
function create_exec_task(trade_date::Int, symbol::String,
                          target_side::String, volume::Int, bid_price::Int64,
                          ask_price::Int64, account_id::String, account_type::Int, 
                          strategy_id::String)::String
    
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
    
    # 检查是否已有活跃任务
    if haskey(exec_symbol_tasks, symbol)
        existing_task_id = exec_symbol_tasks[symbol]
        if haskey(exec_active_tasks, existing_task_id)
            old_task = exec_active_tasks[existing_task_id]
            strategy_log(2, "[ExecutionEngineV2] 合约已有活跃任务，执行替换: symbol=$symbol, old_task=$existing_task_id, old_side=$(old_task.target_side), new_side=$target_side")
            canceled_ids = force_cancel_task!(old_task)
        end
        # 清理残留的映射
        delete!(exec_symbol_tasks, symbol)
    end
    
    # 根据是否有待撤委托决定初始状态
    initial_phase = isempty(canceled_ids) ? :evaluating : :canceling
    codeinfo = get_codeinfo(symbol)
    openlock = (codeinfo.open_commission + codeinfo.open_commission_ratio)*2
    closelock = (codeinfo.close_pre_commission + codeinfo.close_pre_commission_ratio)*2
    opentoday = codeinfo.open_commission + codeinfo.open_commission_ratio
    closetoday = codeinfo.close_today_commission + codeinfo.close_today_commission_ratio
    if openlock + closelock < opentoday + closetoday
        task_type = :lock
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
        ""                     # error_msg
    )
    
    # 注册到全局状态
    exec_active_tasks[task_id] = task
    exec_symbol_tasks[symbol] = task_id
    
    strategy_log(2, "[ExecutionEngineV2] 创建执行任务: task=$task_id, symbol=$symbol, side=$target_side, vol=$volume, bid=$bid_price, ask=$ask_price")
    
    # 启动评估
    if initial_phase == :canceling
        strategy_log(2, "[ExecutionEngineV2] 新任务接管旧委托撤单: task=$task_id, pending_cancels=$(join(canceled_ids, ","))")
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

export create_exec_task, cancel_exec_task, engine_notify!, check_all_tasks!
export get_task_status, get_active_tasks
export ExecutionTask

end