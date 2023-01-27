using Documenter
using Literate
using PartitionedArrays

examples_jl  = joinpath(@__DIR__,"examples.jl")
src_dir = joinpath(@__DIR__,"src") 
Literate.markdown(examples_jl,src_dir)

makedocs(
    sitename = "PartitionedArrays.jl",
    format = Documenter.HTML(
        assets = ["assets/custom.css", "assets/favicon.ico",],
    ),
    modules = [PartitionedArrays],
    pages = [
        "Home" => "index.md",
        "usage.md",
        "examples.md",
        "Reference" =>[
                       "reference/backends.md",
                       "reference/primitives.md",
                       "reference/partition.md",
                       "reference/pvector.md",
                       "reference/psparsematrix.md",
                       "reference/helpers.md",
                      ],
        "refindex.md",
    ],
)

deploydocs(
    repo = "github.com/fverdugo/PartitionedArrays.jl.git",
    push_preview = true,
)
