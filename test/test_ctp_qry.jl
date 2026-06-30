# =============================================================================
# 对 src/ctp_qry.jl 的单元测试 —— 不加载完整 HFTCTP 模块、不依赖 hft.dll
#
# 思路：
#   1. 临时构造一个 stub 模块 CtpQryTest，在里面提供：
#        - 一个 fake `lib`（dlopen 一个肯定能 open 的库句柄占位即可，
#          因为我们不会真的 ccall）
#        - import FinancialStruct 里的 cCtp* 类型
#      然后把 ctp_qry.jl 的源码 include 进去。
#   2. 通过 names / isdefined / methods 验证：
#        - 44 个 td_ctp_qry_* 函数全部生成
#        - 每个函数签名是 (req::cCtpQryXxx,)
#        - 都被 export
#   3. 用 @macroexpand 验证宏展开形态正确（一个样本即可）。
# =============================================================================

using Test
using FinancialStruct
using Libdl

const CTP_QRY_FILE = joinpath(@__DIR__, "..", "src", "ctp_qry.jl")
const HFT_DLL = joinpath(@__DIR__, "..", "release",
                         Sys.iswindows() ? "win64" : "linux",
                         Sys.iswindows() ? "hft.dll" : "libhft.so")

# 在隔离 module 里 include ctp_qry.jl。
# 关键：`lib` 不能是 C_NULL —— 否则 dlsym 路径会被推断为「永远不正常返回」(Union{})，
# 测试就无法在不真正 ccall 的前提下验证返回类型。
# 这里 dlopen release 目录下的真实 hft.dll，让 dlsym 有合法句柄；
# 测试本身只查询签名/返回类型/docstring 等静态属性，不真正调用任何 td_ctp_qry_*。
module CtpQryTest
    using Libdl
    const lib = Libdl.dlopen(Main.HFT_DLL)
end

# 把 ctp_qry.jl 的源码直接 include 到 CtpQryTest 里
Base.include(CtpQryTest, CTP_QRY_FILE)

# 期望生成的所有 td_ctp_qry_* 函数 + (TReq, TOut)
# 从 ctp_qry.jl 的 `@_ctp_qry jl_name :c_sym TReq TOut` 行解析得到，避免硬编码。
function _parse_expected_qrys(file::AbstractString)
    triples = Tuple{Symbol,Symbol,Symbol}[]
    for line in eachline(file)
        m = match(r"^@_ctp_qry\s+(\S+)\s+:\S+\s+(\S+)\s+(\S+)", line)
        m === nothing && continue
        push!(triples, (Symbol(m.captures[1]),
                        Symbol(m.captures[2]),
                        Symbol(m.captures[3])))
    end
    return triples
end
const EXPECTED_QRYS = _parse_expected_qrys(CTP_QRY_FILE)

@testset "ctp_qry.jl 静态结构" begin
    @testset "所有函数已定义" begin
        for (fname, _, _) in EXPECTED_QRYS
            @test isdefined(CtpQryTest, fname)
        end
    end

    @testset "函数签名是 (req::TReq,)" begin
        for (fname, treq_sym, _) in EXPECTED_QRYS
            f = getfield(CtpQryTest, fname)
            TReq = getfield(FinancialStruct, treq_sym)
            # 应当存在一个 (TReq,) 形参的方法
            ms = methods(f)
            sigs = [Tuple(m.sig.parameters[2:end]) for m in ms]
            @test (TReq,) in sigs
        end
    end

    @testset "所有函数都被 export" begin
        exported = Set(names(CtpQryTest; all=false))
        for (fname, _, _) in EXPECTED_QRYS
            @test fname in exported
        end
    end

    @testset "覆盖数量与 hft_ctp_api.h 一致" begin
        # 直接数头文件中 td_ctp_qry_* 函数声明
        header = joinpath(@__DIR__, "..", "release", "include", "hft_ctp_api.h")
        n_header = count(line -> occursin(r"^HFT_API\s+int\s+td_ctp_qry_", line),
                         eachline(header))
        generated = filter(s -> startswith(string(s), "td_ctp_qry_"),
                           names(CtpQryTest; all=false))
        @test length(EXPECTED_QRYS) == n_header
        @test length(generated)    == n_header
    end

    @testset "调度器 _td_ctp_qry_call 也已定义" begin
        @test isdefined(CtpQryTest, :_td_ctp_qry_call)
    end
end

@testset "ctp_qry.jl 宏展开" begin
    # 抽样：用宏展开一个具体调用，检查关键结构
    ex = @macroexpand CtpQryTest.@_ctp_qry td_ctp_qry_demo :td_ctp_qry_order cCtpQryOrder cCtpOrder
    # 展开后应包含 function 定义 + export
    src = string(ex)
    @test occursin("td_ctp_qry_demo", src)
    @test occursin("cCtpQryOrder", src)
    @test occursin("cCtpOrder", src)
    @test occursin(":td_ctp_qry_order", src)   # QuoteNode 保留为 Symbol 字面量
    @test occursin("_td_ctp_qry_call", src)
    @test occursin("export", src)
end

@testset "ctp_qry.jl 完整 docstring 已绑定到每个函数" begin
    # 方案 B：每条 docstring 都应当包含「签名 + 参数 + 返回 + 备注」四段
    # 返回值已简化为单一 Vector{cCtpXxx}（与 td_get_cash 风格一致：err != 0 返回空向量）
    docdict = Docs.meta(CtpQryTest)
    for (fname, _, _) in EXPECTED_QRYS
        binding = Docs.Binding(CtpQryTest, fname)
        @testset "$fname" begin
            @test haskey(docdict, binding)
            multidoc = docdict[binding]
            @test !isempty(multidoc.docs)
            doc = join((string(d.text...) for d in values(multidoc.docs)), "\n")

            @test !isempty(strip(doc))
            @test occursin(string(fname), doc)        # 签名段含函数名
            @test occursin("->", doc)                  # 签名段的返回箭头
            @test occursin("# 参数", doc)
            @test occursin("# 返回", doc)
            @test occursin("# 备注", doc)
            # 新风格：返回单一 Vector，旧的 err/records/total 三元组术语都不应再出现
            @test occursin(r"Vector\{cCtp\w+\}", doc)
            @test !occursin("err::Cint", doc)
            @test !occursin("records::Vector", doc)
            @test !occursin("total::Cint", doc)
        end
    end
end

@testset "ctp_qry.jl 返回类型推断为 Vector{TOut}" begin
    # 编译期断言：每个 td_ctp_qry_xxx 在传入对应 cCtpQryXxx 时，
    # 推断出的返回类型必须精确等于 Vector{对应的 TOut}。
    # 注意：stub 模块里 `lib` 必须是真实 dlopen 拿到的合法句柄，否则推断会退化为 Union{}。
    for (fname, treq_sym, tout_sym) in EXPECTED_QRYS
        f    = getfield(CtpQryTest, fname)
        TReq = getfield(FinancialStruct, treq_sym)
        TOut = getfield(FinancialStruct, tout_sym)
        rts  = Base.return_types(f, (TReq,))
        @testset "$fname" begin
            @test length(rts) == 1
            @test only(rts) == Vector{TOut}
        end
    end
end
