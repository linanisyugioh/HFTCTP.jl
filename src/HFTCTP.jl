module HFTCTP
###using StringEncodings
using CBinding
using Pkg.Artifacts
using FinancialStruct:cOnlyTBTickData,cSecurityTickData,cTickByTickData
using FinancialStruct:cIndexTickData  
using FinancialStruct:cFuturesTickData
using FinancialStruct:cOptionsTickData
using FinancialStruct:cSecurityKdata
using FinancialStruct:cCodeInfo
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

# 使用 Artifacts 动态加载库文件
function __init__()
    # 确保 artifact 可用
    lib_dir = artifact"hftctp_lib"
    # 根据平台设置库路径
    global dlfile
    if Sys.iswindows()
        dlfile = joinpath(lib_dir, "hft.dll")
    elseif Sys.islinux()
        dlfile = joinpath(lib_dir, "libhft.so.1.2.1")
    end
    # 验证库文件是否存在
    if !isfile(dlfile)
        @error "hftctp library files not found. Please make sure the package is installed correctly."
    end
    global lib = Libc.Libdl.dlopen(dlfile)
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
 * @param o_date        输出日期(YYYYMMDD)。
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
"""
"""
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
"""
"""
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

end