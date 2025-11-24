using HFTCTP
using Documenter

DocMeta.setdocmeta!(HFTCTP, :DocTestSetup, :(using HFTCTP); recursive=true)

makedocs(;
    modules=[HFTCTP],
    authors="linan <linanisyugioh@163.com>",
    sitename="HFTCTP.jl",
    format=Documenter.HTML(;
        canonical="https://linanisyugioh.github.io/HFTCTP.jl",
        edit_link="master",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/linanisyugioh/HFTCTP.jl",
    devbranch="master",
)
