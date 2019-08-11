
mutable struct ModelFrame
    df::AbstractDataFrame
    terms::Terms
    nonmissing::BitArray
    ## mapping from df keys to contrasts matrices
    contrasts::Dict{Symbol, ContrastsMatrix}
end

is_categorical(::AbstractArray{<:Union{Missing, Real}}) = false
is_categorical(::AbstractArray) = true

## Check for non-redundancy of columns.  For instance, if x is a factor with two
## levels, it should be expanded into two columns in y~0+x but only one column
## in y~1+x.  The default is the rank-reduced form (contrasts for n levels only
## produce n-1 columns).  In general, an evaluation term x within a term
## x&y&... needs to be "promoted" to full rank if y&... hasn't already been
## included (either explicitly in the Terms or implicitly by promoting another
## term like z in z&y&...).
##
## This modifies the Terms, setting `trms.is_non_redundant = true` for all non-
## redundant evaluation terms.
function check_non_redundancy!(trms::Terms, df::AbstractDataFrame)

    (n_eterms, n_terms) = size(trms.factors)

    encountered_columns = Vector{eltype(trms.factors)}[]

    if trms.intercept
        push!(encountered_columns, zeros(eltype(trms.factors), n_eterms))
    end

    for i_term in 1:n_terms
        for i_eterm in 1:n_eterms
            ## only need to check eterms that are included and can be promoted
            ## (e.g., categorical variables that expand to multiple mm columns)
            if Bool(trms.factors[i_eterm, i_term]) && is_categorical(df[!, trms.eterms[i_eterm]])
                dropped = trms.factors[:,i_term]
                dropped[i_eterm] = 0

                if dropped ∉ encountered_columns
                    trms.is_non_redundant[i_eterm, i_term] = true
                    push!(encountered_columns, dropped)
                end

            end
        end
        ## once we've checked all the eterms in this term, add it to the list
        ## of encountered terms/columns
        push!(encountered_columns, view(trms.factors, :, i_term))
    end

    return trms.is_non_redundant
end

const DEFAULT_CONTRASTS = DummyCoding

# get unique values, honoring levels order
_unique(x::AbstractCategoricalArray) = intersect(levels(x), unique(x))
_unique(x::AbstractCategoricalArray{T}) where {T>:Missing} =
    convert(Array{Missings.T(T)}, filter!(!ismissing, intersect(levels(x), unique(x))))

function _unique(x::AbstractArray{T}) where T
    levs = T >: Missing ?
           convert(Array{Missings.T(T)}, filter!(!ismissing, unique(x))) :
           unique(x)
    try; sort!(levs); catch; end
    return levs
end

## Set up contrasts:
## Combine actual DF columns and contrast types if necessary to compute the
## actual contrasts matrices, levels, and term names (using DummyCoding
## as the default)
function evalcontrasts(df::AbstractDataFrame, contrasts::Dict = Dict())
    evaledContrasts = Dict()
    for (term, col) in eachcol(df, true)
        is_categorical(col) || continue
        evaledContrasts[term] = ContrastsMatrix(haskey(contrasts, term) ?
                                                contrasts[term] :
                                                DEFAULT_CONTRASTS(),
                                                _unique(col))
    end
    return evaledContrasts
end

## Default NULL handler.  Others can be added as keyword arguments
function missing_omit(df::DataFrame)
    cc = completecases(df)
    df[cc,:], cc
end

_droplevels!(x::Any) = x
_droplevels!(x::AbstractCategoricalArray) = droplevels!(x)

function ModelFrame(trms::Terms, d::AbstractDataFrame;
                    contrasts::Dict = Dict())
    df, nonmissing = missing_omit(DataFrame(map(x -> d[!, x], trms.eterms), Symbol.(trms.eterms)))
    names!(df, Symbol.(string.(trms.eterms)))

    evaledContrasts = evalcontrasts(df, contrasts)

    ## Check for non-redundant terms, modifying terms in place
    check_non_redundancy!(trms, df)

    ModelFrame(df, trms, nonmissing, evaledContrasts)
end

ModelFrame(df::AbstractDataFrame, term::Terms, nonmissing::BitArray) = ModelFrame(df, term, nonmissing, evalcontrasts(df))
ModelFrame(f::Formula, d::AbstractDataFrame; kwargs...) = ModelFrame(Terms(f), d; kwargs...)
ModelFrame(ex::Expr, d::AbstractDataFrame; kwargs...) = ModelFrame(Formula(ex), d; kwargs...)


function setcontrasts!(mf::ModelFrame, new_contrasts::Dict)
    for (col, contr) in new_contrasts
        haskey(mf.df, col) || continue
        mf.contrasts[col] = ContrastsMatrix(contr, _unique(mf.df[!, col]))
    end
    return mf
end
setcontrasts!(mf::ModelFrame; kwargs...) = setcontrasts!(mf, Dict(kwargs))


function StatsBase.model_response(mf::ModelFrame)
    if mf.terms.response
        _response = mf.df[!, mf.terms.eterms[1]]
        T = Missings.T(eltype(_response))
        convert(Array{T}, _response)
    else
        error("Model formula one-sided")
    end
end


termnames(term::Symbol, col) = [string(term)]
function termnames(term::Symbol, mf::ModelFrame; non_redundant::Bool = false)
    if haskey(mf.contrasts, term)
        termnames(term, mf.df[!, term],
                  non_redundant ?
                  convert(ContrastsMatrix{FullDummyCoding}, mf.contrasts[term]) :
                  mf.contrasts[term])
    else
        termnames(term, mf.df[!, term])
    end
end

termnames(term::Symbol, col::Any, contrast::ContrastsMatrix) =
    ["$term: $name" for name in contrast.termnames]


function expandtermnames(term::Vector)
    if length(term) == 1
        return term[1]
    else
        return foldr((a,b) -> vec([string(lev1, " & ", lev2) for
                                   lev1 in a,
                                   lev2 in b]),
                     term)
    end
end


function StatsBase.coefnames(mf::ModelFrame)
    terms = droprandomeffects(dropresponse!(mf.terms))

    ## strategy mirrors ModelMatrx constructor:
    eterm_names = Dict{Tuple{Symbol,Bool}, Vector{String}}()
    term_names = Vector{Vector{String}}()

    if terms.intercept
        push!(term_names, String["(Intercept)"])
    end

    factors = terms.factors

    for (i_term, term) in enumerate(terms.terms)

        ## names for columns for eval terms
        names = Vector{Vector{String}}()

        ff = view(factors, :, i_term)
        eterms = view(terms.eterms, ff)
        non_redundants = view(terms.is_non_redundant, ff, i_term)

        for (et, nr) in zip(eterms, non_redundants)
            if !haskey(eterm_names, (et, nr))
                eterm_names[(et, nr)] = termnames(et, mf, non_redundant=nr)
            end
            push!(names, eterm_names[(et, nr)])
        end
        push!(term_names, expandtermnames(names))
    end

    reduce(vcat, term_names, init=Vector{String}())
end