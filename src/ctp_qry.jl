# =============================================================================
# CTP 原生查询接口包装 (对应 release/include/hft_ctp_api.h)
#
# 头文件中所有 td_ctp_qry_* 接口都是同一形态：
#
#   int td_ctp_qry_xxx(const CThostFtdcQryXxxField* req,
#                      CThostFtdcXxxField*          out,
#                      int*                         in_out_count,
#                      int*                         out_total);
#
# 调用方需预分配 out 缓冲，把容量写入 *in_out_count；返回后 *in_out_count 为
# 实际拷贝条数，*out_total 为柜台端总条数。若 *out_total > 输入容量表示截断，
# 不算错误。本文件统一封装：内部预分配 → 调用 → 截断时按 out_total 扩容重查。
#
# 调用前提：策略登录成功（trade 服务已连接），否则返回 ERR_TD_NOT_INIT。
# =============================================================================

using CBinding
# FinancialStruct 源头里 cCtp* 别名已用 `const` 定义，
# 跨模块 import 后仍是 const binding，类型推断器可做常量传播，
# 所以 `Vector{cCtpXxx}` 这种类型注解能被精确推断到具体 DataType。
import FinancialStruct: cCtpQryMaxOrderVolume,
    cCtpQryOrder, cCtpOrder,
    cCtpQryTrade, cCtpTrade,
    cCtpQryInvestorPosition, cCtpInvestorPosition,
    cCtpQryTradingAccount, cCtpTradingAccount,
    cCtpQryInvestor, cCtpInvestor,
    cCtpQryTradingCode, cCtpTradingCode,
    cCtpQryInstrumentMarginRate, cCtpInstrumentMarginRate,
    cCtpQryInstrumentCommissionRate, cCtpInstrumentCommissionRate,
    cCtpQryExchange, cCtpExchange,
    cCtpQryProduct, cCtpProduct,
    cCtpQryInstrument, cCtpInstrument,
    cCtpQryDepthMarketData, cCtpDepthMarketData,
    cCtpQrySettlementInfo, cCtpSettlementInfo,
    cCtpQryTransferBank, cCtpTransferBank,
    cCtpQryInvestorPositionDetail, cCtpInvestorPositionDetail,
    cCtpQryNotice, cCtpNotice,
    cCtpQrySettlementInfoConfirm, cCtpSettlementInfoConfirm,
    cCtpQryInvestorPositionCombineDetail, cCtpInvestorPositionCombineDetail,
    cCtpQryCFMMCTradingAccountKey, cCtpCFMMCTradingAccountKey,
    cCtpQryEWarrantOffset, cCtpEWarrantOffset,
    cCtpQryInvestorProductGroupMargin, cCtpInvestorProductGroupMargin,
    cCtpQryExchangeMarginRate, cCtpExchangeMarginRate,
    cCtpQryExchangeMarginRateAdjust, cCtpExchangeMarginRateAdjust,
    cCtpQryExchangeRate, cCtpExchangeRate,
    cCtpQrySecAgentACIDMap, cCtpSecAgentACIDMap,
    cCtpQryProductExchRate, cCtpProductExchRate,
    cCtpQryProductGroup, cCtpProductGroup,
    cCtpQryMMInstrumentCommissionRate, cCtpMMInstrumentCommissionRate,
    cCtpQryMMOptionInstrCommRate, cCtpMMOptionInstrCommRate,
    cCtpQryInstrumentOrderCommRate, cCtpInstrumentOrderCommRate,
    cCtpQrySecAgentCheckMode, cCtpSecAgentCheckMode,
    cCtpQrySecAgentTradeInfo, cCtpSecAgentTradeInfo,
    cCtpQryOptionInstrTradeCost, cCtpOptionInstrTradeCost,
    cCtpQryOptionInstrCommRate, cCtpOptionInstrCommRate,
    cCtpQryExecOrder, cCtpExecOrder,
    cCtpQryForQuote, cCtpForQuote,
    cCtpQryQuote, cCtpQuote,
    cCtpQryOptionSelfClose, cCtpOptionSelfClose,
    cCtpQryInvestUnit, cCtpInvestUnit,
    cCtpQryCombInstrumentGuard, cCtpCombInstrumentGuard,
    cCtpQryCombAction, cCtpCombAction,
    cCtpQryTransferSerial, cCtpTransferSerial,
    cCtpQryAccountregister, cCtpAccountregister,
    cCtpQryContractBank, cCtpContractBank,
    cCtpQryParkedOrder, cCtpParkedOrder,
    cCtpQryParkedOrderAction, cCtpParkedOrderAction,
    cCtpQryTradingNotice, cCtpTradingNotice,
    cCtpQryBrokerTradingParams, cCtpBrokerTradingParams,
    cCtpQryBrokerTradingAlgos, cCtpBrokerTradingAlgos,
    cCtpQryClassifiedInstrument,
    cCtpQryCombPromotionParam, cCtpCombPromotionParam,
    cCtpQryRiskSettleInvstPosition, cCtpRiskSettleInvstPosition,
    cCtpQryRiskSettleProductStatus, cCtpRiskSettleProductStatus

# =============================================================================
# 调度器：两次试探拿全数据
# =============================================================================

"""
    _td_ctp_qry_call(symname, ::Type{TOut}, req) -> Vector{TOut}

通用查询调度器（两次试探）：
  - 第一次：以 `Vector{TOut}(undef, 1)`、`in_out=1`、`total=0` 作为输入调用 ccall，
    柜台返回时 `*total` 即为实际总条数。
  - 第二次：按 `total` 精确分配 `Vector{TOut}(undef, total)` 再调一次，把数据拿全。
  - 与 `td_get_cash` 风格一致：失败（err != 0）或柜台 0 条数据时统一返回空向量；
    成功且有数据时返回长度等于柜台端总条数的 `Vector{TOut}`。

调用方需保证 `typeof(req)` 与头文件里对应 td_ctp_qry_* 的 const 请求结构体类型匹配；
`TOut` 是对应响应结构体类型。两个类型解耦让一个调度器服务所有 55 个查询接口。
"""
function _td_ctp_qry_call(symname::Symbol,
                          ::Type{TOut},
                          req::TReq)::Vector{TOut} where {TReq,TOut}
    sym = Libc.Libdl.dlsym(lib, symname)
    req_ref = Ref{TReq}(req)

    # 第 1 次：探条数。cap=1 即可让柜台把 total 写回（截断不算错误）
    probe = Vector{TOut}(undef, 1)
    in_out = Ref{Cint}(1)
    total  = Ref{Cint}(0)
    err = ccall(sym, Cint,
                (Ptr{TReq}, Ptr{TOut}, Ptr{Cint}, Ptr{Cint}),
                req_ref, probe, in_out, total)
    err != 0 && return TOut[]
    total[] == 0 && return TOut[]

    # 第 2 次：按 total 精确分配
    cap = total[]
    buf = Vector{TOut}(undef, cap)
    in_out[] = cap
    total[]  = 0
    err = ccall(sym, Cint,
                (Ptr{TReq}, Ptr{TOut}, Ptr{Cint}, Ptr{Cint}),
                req_ref, buf, in_out, total)
    err != 0 && return TOut[]
    resize!(buf, in_out[])
    return buf
end

# -----------------------------------------------------------------------------
# 包装器宏：为每个 td_ctp_qry_xxx 生成一个同名 Julia 函数
# 形态统一：jl_name(req::TReq) -> Vector{TOut}
#   - 与 td_get_cash 等接口风格一致：err != 0 时返回空向量
# -----------------------------------------------------------------------------
macro _ctp_qry(jl_name, c_sym, TReq, TOut)
    # c_sym 调用时写作 `:td_ctp_qry_xxx`，宏解析后是 QuoteNode；直接插值即可，
    # 不能再套 QuoteNode（那样会变成「Symbol 的 Symbol」）
    #
    # 这里返回类型注解 `::Vector{$(esc(TOut))}` 让编译器把 TOut 锁定为
    # 该宏调用站点的具体类型，避免 _td_ctp_qry_call 内部因 ::Type{TOut} 形参
    # 在调用时被推断为基类 `Type` 而退化为无参 `Vector`。
    quote
        Core.@__doc__ function $(esc(jl_name))(req::$(esc(TReq)))::Vector{$(esc(TOut))}
            return _td_ctp_qry_call($c_sym, $(esc(TOut)), req)
        end
        export $(esc(jl_name))
    end
end

# -----------------------------------------------------------------------------
# 55 个查询接口
#
# 每条文档块统一格式：
#     函数签名（含返回类型）
#     中文标题
#     # 参数 / # 返回 / # 备注
# -----------------------------------------------------------------------------

"""
    td_ctp_qry_max_order_volume(req::cCtpQryMaxOrderVolume) -> Vector{cCtpQryMaxOrderVolume}

查询最大报单数量。该接口请求与响应复用同一结构体 `cCtpQryMaxOrderVolume`。

# 参数
- `req::cCtpQryMaxOrderVolume`：查询条件（调用方填 Direction/OffsetFlag/HedgeFlag/ExchangeID/InstrumentID 等）；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpQryMaxOrderVolume}`：查询结果。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_max_order_volume`；内部走两次试探（先探 total，再按 total 精确分配缓冲）拿全数据。
"""
@_ctp_qry td_ctp_qry_max_order_volume :td_ctp_qry_max_order_volume cCtpQryMaxOrderVolume cCtpQryMaxOrderVolume

"""
    td_ctp_qry_order(req::cCtpQryOrder) -> Vector{cCtpOrder}

查询报单。

# 参数
- `req::cCtpQryOrder`：查询条件（ExchangeID/InstrumentID/OrderSysID/时间范围等）；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpOrder}`：报单记录。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_order`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_order :td_ctp_qry_order cCtpQryOrder cCtpOrder

"""
    td_ctp_qry_trade(req::cCtpQryTrade) -> Vector{cCtpTrade}

查询成交。

# 参数
- `req::cCtpQryTrade`：查询条件；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpTrade}`：成交记录。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_trade`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_trade :td_ctp_qry_trade cCtpQryTrade cCtpTrade

"""
    td_ctp_qry_investor_position(req::cCtpQryInvestorPosition) -> Vector{cCtpInvestorPosition}

查询投资者持仓汇总。

# 参数
- `req::cCtpQryInvestorPosition`：查询条件；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpInvestorPosition}`：持仓汇总。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_investor_position`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_investor_position :td_ctp_qry_investor_position cCtpQryInvestorPosition cCtpInvestorPosition

"""
    td_ctp_qry_trading_account(req::cCtpQryTradingAccount) -> Vector{cCtpTradingAccount}

查询资金账户。

# 参数
- `req::cCtpQryTradingAccount`：查询条件；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpTradingAccount}`：资金账户。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_trading_account`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_trading_account :td_ctp_qry_trading_account cCtpQryTradingAccount cCtpTradingAccount

"""
    td_ctp_qry_investor(req::cCtpQryInvestor) -> Vector{cCtpInvestor}

查询投资者信息。

# 参数
- `req::cCtpQryInvestor`：查询条件；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpInvestor}`：投资者信息。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_investor`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_investor :td_ctp_qry_investor cCtpQryInvestor cCtpInvestor

"""
    td_ctp_qry_trading_code(req::cCtpQryTradingCode) -> Vector{cCtpTradingCode}

查询交易编码。

# 参数
- `req::cCtpQryTradingCode`：查询条件；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpTradingCode}`：交易编码记录。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_trading_code`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_trading_code :td_ctp_qry_trading_code cCtpQryTradingCode cCtpTradingCode

"""
    td_ctp_qry_instrument_margin_rate(req::cCtpQryInstrumentMarginRate) -> Vector{cCtpInstrumentMarginRate}

查询合约保证金率。

# 参数
- `req::cCtpQryInstrumentMarginRate`：查询条件；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpInstrumentMarginRate}`：合约保证金率。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_instrument_margin_rate`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_instrument_margin_rate :td_ctp_qry_instrument_margin_rate cCtpQryInstrumentMarginRate cCtpInstrumentMarginRate

"""
    td_ctp_qry_instrument_commission_rate(req::cCtpQryInstrumentCommissionRate) -> Vector{cCtpInstrumentCommissionRate}

查询合约手续费率。

# 参数
- `req::cCtpQryInstrumentCommissionRate`：查询条件；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpInstrumentCommissionRate}`：合约手续费率。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_instrument_commission_rate`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_instrument_commission_rate :td_ctp_qry_instrument_commission_rate cCtpQryInstrumentCommissionRate cCtpInstrumentCommissionRate

"""
    td_ctp_qry_exchange(req::cCtpQryExchange) -> Vector{cCtpExchange}

查询交易所。

# 参数
- `req::cCtpQryExchange`：查询条件（按 ExchangeID 等过滤）。该结构体不含 BrokerID/InvestorID，框架不填任何身份字段。

# 返回
- `Vector{cCtpExchange}`：交易所记录。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_exchange`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_exchange :td_ctp_qry_exchange cCtpQryExchange cCtpExchange

"""
    td_ctp_qry_product(req::cCtpQryProduct) -> Vector{cCtpProduct}

查询产品。

# 参数
- `req::cCtpQryProduct`：查询条件（按 ProductID/ProductClass 等过滤）。

# 返回
- `Vector{cCtpProduct}`：产品记录。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_product`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_product :td_ctp_qry_product cCtpQryProduct cCtpProduct

"""
    td_ctp_qry_instrument(req::cCtpQryInstrument) -> Vector{cCtpInstrument}

查询合约。

# 参数
- `req::cCtpQryInstrument`：查询条件（按 InstrumentID/ExchangeID/ProductID 等过滤）。

# 返回
- `Vector{cCtpInstrument}`：合约信息。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_instrument`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_instrument :td_ctp_qry_instrument cCtpQryInstrument cCtpInstrument

"""
    td_ctp_qry_depth_market_data(req::cCtpQryDepthMarketData) -> Vector{cCtpDepthMarketData}

查询行情快照（深度行情）。

# 参数
- `req::cCtpQryDepthMarketData`：查询条件（按 InstrumentID 等过滤）。

# 返回
- `Vector{cCtpDepthMarketData}`：行情快照。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_depth_market_data`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_depth_market_data :td_ctp_qry_depth_market_data cCtpQryDepthMarketData cCtpDepthMarketData

"""
    td_ctp_qry_settlement_info(req::cCtpQrySettlementInfo) -> Vector{cCtpSettlementInfo}

查询投资者结算结果。

# 参数
- `req::cCtpQrySettlementInfo`：查询条件（TradingDay 等）；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpSettlementInfo}`：结算结果。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_settlement_info`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_settlement_info :td_ctp_qry_settlement_info cCtpQrySettlementInfo cCtpSettlementInfo

"""
    td_ctp_qry_transfer_bank(req::cCtpQryTransferBank) -> Vector{cCtpTransferBank}

查询转账银行。

# 参数
- `req::cCtpQryTransferBank`：查询条件（BankID 等）。

# 返回
- `Vector{cCtpTransferBank}`：转账银行信息。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_transfer_bank`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_transfer_bank :td_ctp_qry_transfer_bank cCtpQryTransferBank cCtpTransferBank

"""
    td_ctp_qry_investor_position_detail(req::cCtpQryInvestorPositionDetail) -> Vector{cCtpInvestorPositionDetail}

查询投资者持仓明细（按手）。

# 参数
- `req::cCtpQryInvestorPositionDetail`：查询条件；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpInvestorPositionDetail}`：持仓明细。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_investor_position_detail`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_investor_position_detail :td_ctp_qry_investor_position_detail cCtpQryInvestorPositionDetail cCtpInvestorPositionDetail

"""
    td_ctp_qry_notice(req::cCtpQryNotice) -> Vector{cCtpNotice}

查询通知。

# 参数
- `req::cCtpQryNotice`：查询条件；BrokerID 由框架自动填写。

# 返回
- `Vector{cCtpNotice}`：通知记录。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_notice`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_notice :td_ctp_qry_notice cCtpQryNotice cCtpNotice

"""
    td_ctp_qry_settlement_info_confirm(req::cCtpQrySettlementInfoConfirm) -> Vector{cCtpSettlementInfoConfirm}

查询投资者结算结果确认信息。

# 参数
- `req::cCtpQrySettlementInfoConfirm`：查询条件；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpSettlementInfoConfirm}`：结算确认记录。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_settlement_info_confirm`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_settlement_info_confirm :td_ctp_qry_settlement_info_confirm cCtpQrySettlementInfoConfirm cCtpSettlementInfoConfirm

"""
    td_ctp_qry_investor_position_combine_detail(req::cCtpQryInvestorPositionCombineDetail) -> Vector{cCtpInvestorPositionCombineDetail}

查询投资者组合持仓明细。

# 参数
- `req::cCtpQryInvestorPositionCombineDetail`：查询条件；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpInvestorPositionCombineDetail}`：组合持仓明细。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_investor_position_combine_detail`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_investor_position_combine_detail :td_ctp_qry_investor_position_combine_detail cCtpQryInvestorPositionCombineDetail cCtpInvestorPositionCombineDetail

"""
    td_ctp_qry_cfmmc_trading_account_key(req::cCtpQryCFMMCTradingAccountKey) -> Vector{cCtpCFMMCTradingAccountKey}

查询银期转账密钥（保证金监控中心交易账户密钥）。

# 参数
- `req::cCtpQryCFMMCTradingAccountKey`：查询条件；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpCFMMCTradingAccountKey}`：密钥记录。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_cfmmc_trading_account_key`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_cfmmc_trading_account_key :td_ctp_qry_cfmmc_trading_account_key cCtpQryCFMMCTradingAccountKey cCtpCFMMCTradingAccountKey

"""
    td_ctp_qry_ewarrant_offset(req::cCtpQryEWarrantOffset) -> Vector{cCtpEWarrantOffset}

查询仓单折抵信息。

# 参数
- `req::cCtpQryEWarrantOffset`：查询条件；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpEWarrantOffset}`：仓单折抵记录。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_ewarrant_offset`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_ewarrant_offset :td_ctp_qry_ewarrant_offset cCtpQryEWarrantOffset cCtpEWarrantOffset

"""
    td_ctp_qry_investor_product_group_margin(req::cCtpQryInvestorProductGroupMargin) -> Vector{cCtpInvestorProductGroupMargin}

查询投资者产品组保证金。

# 参数
- `req::cCtpQryInvestorProductGroupMargin`：查询条件；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpInvestorProductGroupMargin}`：产品组保证金。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_investor_product_group_margin`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_investor_product_group_margin :td_ctp_qry_investor_product_group_margin cCtpQryInvestorProductGroupMargin cCtpInvestorProductGroupMargin

"""
    td_ctp_qry_exchange_margin_rate(req::cCtpQryExchangeMarginRate) -> Vector{cCtpExchangeMarginRate}

查询交易所保证金率。

# 参数
- `req::cCtpQryExchangeMarginRate`：查询条件；BrokerID 由框架自动填写。

# 返回
- `Vector{cCtpExchangeMarginRate}`：交易所保证金率。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_exchange_margin_rate`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_exchange_margin_rate :td_ctp_qry_exchange_margin_rate cCtpQryExchangeMarginRate cCtpExchangeMarginRate

"""
    td_ctp_qry_exchange_margin_rate_adjust(req::cCtpQryExchangeMarginRateAdjust) -> Vector{cCtpExchangeMarginRateAdjust}

查询交易所保证金率调整。

# 参数
- `req::cCtpQryExchangeMarginRateAdjust`：查询条件；BrokerID 由框架自动填写。

# 返回
- `Vector{cCtpExchangeMarginRateAdjust}`：保证金率调整。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_exchange_margin_rate_adjust`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_exchange_margin_rate_adjust :td_ctp_qry_exchange_margin_rate_adjust cCtpQryExchangeMarginRateAdjust cCtpExchangeMarginRateAdjust

"""
    td_ctp_qry_exchange_rate(req::cCtpQryExchangeRate) -> Vector{cCtpExchangeRate}

查询汇率。

# 参数
- `req::cCtpQryExchangeRate`：查询条件。

# 返回
- `Vector{cCtpExchangeRate}`：汇率记录。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_exchange_rate`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_exchange_rate :td_ctp_qry_exchange_rate cCtpQryExchangeRate cCtpExchangeRate

"""
    td_ctp_qry_sec_agent_acid_map(req::cCtpQrySecAgentACIDMap) -> Vector{cCtpSecAgentACIDMap}

查询二级代理资金账户映射。

# 参数
- `req::cCtpQrySecAgentACIDMap`：查询条件；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpSecAgentACIDMap}`：账户映射记录。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_sec_agent_acid_map`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_sec_agent_acid_map :td_ctp_qry_sec_agent_acid_map cCtpQrySecAgentACIDMap cCtpSecAgentACIDMap

"""
    td_ctp_qry_product_exch_rate(req::cCtpQryProductExchRate) -> Vector{cCtpProductExchRate}

查询产品汇率。

# 参数
- `req::cCtpQryProductExchRate`：查询条件。

# 返回
- `Vector{cCtpProductExchRate}`：产品汇率。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_product_exch_rate`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_product_exch_rate :td_ctp_qry_product_exch_rate cCtpQryProductExchRate cCtpProductExchRate

"""
    td_ctp_qry_product_group(req::cCtpQryProductGroup) -> Vector{cCtpProductGroup}

查询产品组。

# 参数
- `req::cCtpQryProductGroup`：查询条件。

# 返回
- `Vector{cCtpProductGroup}`：产品组信息。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_product_group`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_product_group :td_ctp_qry_product_group cCtpQryProductGroup cCtpProductGroup

"""
    td_ctp_qry_mm_instrument_commission_rate(req::cCtpQryMMInstrumentCommissionRate) -> Vector{cCtpMMInstrumentCommissionRate}

查询做市商合约手续费率。

# 参数
- `req::cCtpQryMMInstrumentCommissionRate`：查询条件；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpMMInstrumentCommissionRate}`：做市商手续费率。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_mm_instrument_commission_rate`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_mm_instrument_commission_rate :td_ctp_qry_mm_instrument_commission_rate cCtpQryMMInstrumentCommissionRate cCtpMMInstrumentCommissionRate

"""
    td_ctp_qry_mm_option_instr_comm_rate(req::cCtpQryMMOptionInstrCommRate) -> Vector{cCtpMMOptionInstrCommRate}

查询做市商期权合约手续费率。

# 参数
- `req::cCtpQryMMOptionInstrCommRate`：查询条件；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpMMOptionInstrCommRate}`：做市商期权手续费率。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_mm_option_instr_comm_rate`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_mm_option_instr_comm_rate :td_ctp_qry_mm_option_instr_comm_rate cCtpQryMMOptionInstrCommRate cCtpMMOptionInstrCommRate

"""
    td_ctp_qry_instrument_order_comm_rate(req::cCtpQryInstrumentOrderCommRate) -> Vector{cCtpInstrumentOrderCommRate}

查询合约报单手续费率。

# 参数
- `req::cCtpQryInstrumentOrderCommRate`：查询条件；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpInstrumentOrderCommRate}`：报单手续费率。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_instrument_order_comm_rate`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_instrument_order_comm_rate :td_ctp_qry_instrument_order_comm_rate cCtpQryInstrumentOrderCommRate cCtpInstrumentOrderCommRate

"""
    td_ctp_qry_sec_agent_trading_account(req::cCtpQryTradingAccount) -> Vector{cCtpTradingAccount}

查询二级代理资金账户。请求与响应**复用** `cCtpQryTradingAccount` / `cCtpTradingAccount`。

# 参数
- `req::cCtpQryTradingAccount`：查询条件；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpTradingAccount}`：二级代理资金账户。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_sec_agent_trading_account`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_sec_agent_trading_account :td_ctp_qry_sec_agent_trading_account cCtpQryTradingAccount cCtpTradingAccount

"""
    td_ctp_qry_sec_agent_check_mode(req::cCtpQrySecAgentCheckMode) -> Vector{cCtpSecAgentCheckMode}

查询二级代理校验模式。

# 参数
- `req::cCtpQrySecAgentCheckMode`：查询条件；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpSecAgentCheckMode}`：二级代理校验模式。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_sec_agent_check_mode`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_sec_agent_check_mode :td_ctp_qry_sec_agent_check_mode cCtpQrySecAgentCheckMode cCtpSecAgentCheckMode

"""
    td_ctp_qry_sec_agent_trade_info(req::cCtpQrySecAgentTradeInfo) -> Vector{cCtpSecAgentTradeInfo}

查询二级代理交易信息。

# 参数
- `req::cCtpQrySecAgentTradeInfo`：查询条件；BrokerID 由框架自动填写。

# 返回
- `Vector{cCtpSecAgentTradeInfo}`：二级代理交易信息。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_sec_agent_trade_info`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_sec_agent_trade_info :td_ctp_qry_sec_agent_trade_info cCtpQrySecAgentTradeInfo cCtpSecAgentTradeInfo

"""
    td_ctp_qry_option_instr_trade_cost(req::cCtpQryOptionInstrTradeCost) -> Vector{cCtpOptionInstrTradeCost}

查询期权合约交易成本。

# 参数
- `req::cCtpQryOptionInstrTradeCost`：查询条件；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpOptionInstrTradeCost}`：期权交易成本。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_option_instr_trade_cost`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_option_instr_trade_cost :td_ctp_qry_option_instr_trade_cost cCtpQryOptionInstrTradeCost cCtpOptionInstrTradeCost

"""
    td_ctp_qry_option_instr_comm_rate(req::cCtpQryOptionInstrCommRate) -> Vector{cCtpOptionInstrCommRate}

查询期权合约手续费率。

# 参数
- `req::cCtpQryOptionInstrCommRate`：查询条件；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpOptionInstrCommRate}`：期权手续费率。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_option_instr_comm_rate`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_option_instr_comm_rate :td_ctp_qry_option_instr_comm_rate cCtpQryOptionInstrCommRate cCtpOptionInstrCommRate

"""
    td_ctp_qry_exec_order(req::cCtpQryExecOrder) -> Vector{cCtpExecOrder}

查询执行宣告（期权行权）。

# 参数
- `req::cCtpQryExecOrder`：查询条件；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpExecOrder}`：执行宣告记录。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_exec_order`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_exec_order :td_ctp_qry_exec_order cCtpQryExecOrder cCtpExecOrder

"""
    td_ctp_qry_for_quote(req::cCtpQryForQuote) -> Vector{cCtpForQuote}

查询询价。

# 参数
- `req::cCtpQryForQuote`：查询条件；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpForQuote}`：询价记录。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_for_quote`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_for_quote :td_ctp_qry_for_quote cCtpQryForQuote cCtpForQuote

"""
    td_ctp_qry_quote(req::cCtpQryQuote) -> Vector{cCtpQuote}

查询报价。

# 参数
- `req::cCtpQryQuote`：查询条件；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpQuote}`：报价记录。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_quote`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_quote :td_ctp_qry_quote cCtpQryQuote cCtpQuote

"""
    td_ctp_qry_option_self_close(req::cCtpQryOptionSelfClose) -> Vector{cCtpOptionSelfClose}

查询期权自对冲。

# 参数
- `req::cCtpQryOptionSelfClose`：查询条件；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpOptionSelfClose}`：期权自对冲记录。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_option_self_close`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_option_self_close :td_ctp_qry_option_self_close cCtpQryOptionSelfClose cCtpOptionSelfClose

"""
    td_ctp_qry_invest_unit(req::cCtpQryInvestUnit) -> Vector{cCtpInvestUnit}

查询投资单元。

# 参数
- `req::cCtpQryInvestUnit`：查询条件；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpInvestUnit}`：投资单元。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_invest_unit`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_invest_unit :td_ctp_qry_invest_unit cCtpQryInvestUnit cCtpInvestUnit

"""
    td_ctp_qry_comb_instrument_guard(req::cCtpQryCombInstrumentGuard) -> Vector{cCtpCombInstrumentGuard}

查询组合合约保证金（CombInstrumentGuard）。

# 参数
- `req::cCtpQryCombInstrumentGuard`：查询条件；BrokerID 由框架自动填写。

# 返回
- `Vector{cCtpCombInstrumentGuard}`：组合合约保证金。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_comb_instrument_guard`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_comb_instrument_guard :td_ctp_qry_comb_instrument_guard cCtpQryCombInstrumentGuard cCtpCombInstrumentGuard

"""
    td_ctp_qry_comb_action(req::cCtpQryCombAction) -> Vector{cCtpCombAction}

查询组合动作（组合申请/拆分）。

# 参数
- `req::cCtpQryCombAction`：查询条件；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpCombAction}`：组合动作记录。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_comb_action`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_comb_action :td_ctp_qry_comb_action cCtpQryCombAction cCtpCombAction

"""
    td_ctp_qry_transfer_serial(req::cCtpQryTransferSerial) -> Vector{cCtpTransferSerial}

查询转账流水。

# 参数
- `req::cCtpQryTransferSerial`：查询条件（BankID、起止时间等）；BrokerID 由框架自动填写。

# 返回
- `Vector{cCtpTransferSerial}`：转账流水记录。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_transfer_serial`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_transfer_serial :td_ctp_qry_transfer_serial cCtpQryTransferSerial cCtpTransferSerial

"""
    td_ctp_qry_accountregister(req::cCtpQryAccountregister) -> Vector{cCtpAccountregister}

查询银行账户注册信息。

# 参数
- `req::cCtpQryAccountregister`：查询条件；BrokerID 由框架自动填写。

# 返回
- `Vector{cCtpAccountregister}`：账户注册记录。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_accountregister`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_accountregister :td_ctp_qry_accountregister cCtpQryAccountregister cCtpAccountregister

"""
    td_ctp_qry_contract_bank(req::cCtpQryContractBank) -> Vector{cCtpContractBank}

查询签约银行。

# 参数
- `req::cCtpQryContractBank`：查询条件；BrokerID 由框架自动填写。

# 返回
- `Vector{cCtpContractBank}`：签约银行记录。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_contract_bank`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_contract_bank :td_ctp_qry_contract_bank cCtpQryContractBank cCtpContractBank

"""
    td_ctp_qry_parked_order(req::cCtpQryParkedOrder) -> Vector{cCtpParkedOrder}

查询预埋单。

# 参数
- `req::cCtpQryParkedOrder`：查询条件；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpParkedOrder}`：预埋单。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_parked_order`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_parked_order :td_ctp_qry_parked_order cCtpQryParkedOrder cCtpParkedOrder

"""
    td_ctp_qry_parked_order_action(req::cCtpQryParkedOrderAction) -> Vector{cCtpParkedOrderAction}

查询预埋撤单。

# 参数
- `req::cCtpQryParkedOrderAction`：查询条件；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpParkedOrderAction}`：预埋撤单。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_parked_order_action`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_parked_order_action :td_ctp_qry_parked_order_action cCtpQryParkedOrderAction cCtpParkedOrderAction

"""
    td_ctp_qry_trading_notice(req::cCtpQryTradingNotice) -> Vector{cCtpTradingNotice}

查询交易通知。

# 参数
- `req::cCtpQryTradingNotice`：查询条件；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpTradingNotice}`：交易通知。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_trading_notice`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_trading_notice :td_ctp_qry_trading_notice cCtpQryTradingNotice cCtpTradingNotice

"""
    td_ctp_qry_broker_trading_params(req::cCtpQryBrokerTradingParams) -> Vector{cCtpBrokerTradingParams}

查询经纪公司交易参数。

# 参数
- `req::cCtpQryBrokerTradingParams`：查询条件；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpBrokerTradingParams}`：交易参数。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_broker_trading_params`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_broker_trading_params :td_ctp_qry_broker_trading_params cCtpQryBrokerTradingParams cCtpBrokerTradingParams

"""
    td_ctp_qry_broker_trading_algos(req::cCtpQryBrokerTradingAlgos) -> Vector{cCtpBrokerTradingAlgos}

查询经纪公司交易算法。

# 参数
- `req::cCtpQryBrokerTradingAlgos`：查询条件；BrokerID 由框架自动填写。

# 返回
- `Vector{cCtpBrokerTradingAlgos}`：交易算法。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_broker_trading_algos`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_broker_trading_algos :td_ctp_qry_broker_trading_algos cCtpQryBrokerTradingAlgos cCtpBrokerTradingAlgos

"""
    td_ctp_qry_classified_instrument(req::cCtpQryClassifiedInstrument) -> Vector{cCtpInstrument}

查询分类合约。响应**复用** `cCtpInstrument`。

# 参数
- `req::cCtpQryClassifiedInstrument`：查询条件（分类筛选合约）；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpInstrument}`：分类合约信息。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_classified_instrument`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_classified_instrument :td_ctp_qry_classified_instrument cCtpQryClassifiedInstrument cCtpInstrument

"""
    td_ctp_qry_comb_promotion_param(req::cCtpQryCombPromotionParam) -> Vector{cCtpCombPromotionParam}

查询组合促销参数。

# 参数
- `req::cCtpQryCombPromotionParam`：查询条件；BrokerID 由框架自动填写。

# 返回
- `Vector{cCtpCombPromotionParam}`：组合促销参数。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_comb_promotion_param`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_comb_promotion_param :td_ctp_qry_comb_promotion_param cCtpQryCombPromotionParam cCtpCombPromotionParam

"""
    td_ctp_qry_risk_settle_invst_position(req::cCtpQryRiskSettleInvstPosition) -> Vector{cCtpRiskSettleInvstPosition}

查询风险结算投资者持仓。

# 参数
- `req::cCtpQryRiskSettleInvstPosition`：查询条件；BrokerID/InvestorID 由框架自动填写。

# 返回
- `Vector{cCtpRiskSettleInvstPosition}`：风险结算持仓。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_risk_settle_invst_position`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_risk_settle_invst_position :td_ctp_qry_risk_settle_invst_position cCtpQryRiskSettleInvstPosition cCtpRiskSettleInvstPosition

"""
    td_ctp_qry_risk_settle_product_status(req::cCtpQryRiskSettleProductStatus) -> Vector{cCtpRiskSettleProductStatus}

查询风险结算产品状态。

# 参数
- `req::cCtpQryRiskSettleProductStatus`：查询条件；BrokerID 由框架自动填写。

# 返回
- `Vector{cCtpRiskSettleProductStatus}`：风险结算产品状态。失败（柜台返回错误码）或无数据时为空向量。

# 备注
对应 C 接口 `td_ctp_qry_risk_settle_product_status`；内部走两次试探拿全数据。
"""
@_ctp_qry td_ctp_qry_risk_settle_product_status :td_ctp_qry_risk_settle_product_status cCtpQryRiskSettleProductStatus cCtpRiskSettleProductStatus
