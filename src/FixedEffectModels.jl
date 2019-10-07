
module FixedEffectModels

##############################################################################
##
## Dependencies
##
##############################################################################
using Base
using LinearAlgebra
using Statistics
using Printf
using FillArrays
using CategoricalArrays
using DataFrames
using Distributions
using Reexport
@reexport using StatsBase
@reexport using StatsModels
@reexport using Vcov

using FixedEffects

##############################################################################
##
## Exported methods and types
##
##############################################################################

export reg,
partial_out,
fe,
fes,

FixedEffectModel,
has_iv,
has_fe,

#deprecated
@model


##############################################################################
##
## Load files
##
##############################################################################
include("utils/fixedeffects.jl")
include("utils/basecol.jl")
include("utils/tss.jl")
include("utils/model.jl")
include("utils/formula.jl")

include("FixedEffectModel.jl")
include("fit.jl")
include("partial_out.jl")

# precompile script
df = DataFrame(y = [1, 1], x =[1, 2], id = [1, 1])
reg(df, @formula(y ~ x + fe(id)))
reg(df, @formula(y ~ x), Vcov.cluster(:id))

end  # module FixedEffectModels
