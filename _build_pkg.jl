using Pkg
using Pkg.Artifacts
using Pkg.BinaryPlatforms

# 设置代理
ENV["http_proxy"] = "http://127.0.0.1:7890"
ENV["https_proxy"] = "http://127.0.0.1:7890"

# 自动从 Project.toml 读取包名和项目路径
project_path = @__DIR__
toml = Pkg.TOML.parsefile(joinpath(project_path, "Project.toml"))
pkg_name = toml["name"]

@info "正在打包: $pkg_name (路径: $project_path)"

try
    Pkg.rm(pkg_name)
catch e
    @info "Pkg.rm 跳过（包不在当前 project 中）: $(e.msg)"
end
Pkg.add(path=project_path)

# 在 Windows 平台上下载 Linux 的 artifact（用于交叉编译或验证）
@info "检查并下载 Linux artifact..."
try
    # 直接从 Artifacts.toml 安装 Linux artifact，不依赖模块加载
    artifacts_toml = joinpath(project_path, "Artifacts.toml")
    if isfile(artifacts_toml)
        linux_dir = ensure_artifact_installed("hftctp_lib", artifacts_toml; platform=Platform("x86_64", "linux"))
        @info "Linux artifact 已安装到: $linux_dir"
    else
        @warn "Artifacts.toml 不存在: $artifacts_toml"
    end
catch e
    @warn "下载 Linux artifact 失败: $e"
end
