"""
Estimate a linear model with high dimensional categorical variables / instrumental variables

### Arguments
* `df`: a Table
* `FormulaTerm`: A formula created using [`@formula`](@ref)
* `save::Union{Bool, Symbol} = false`: Should residuals and eventual estimated fixed effects saved in a dataframe? Use `save = :residuals` to only save residuals. Use `save = :fe` to only save fixed effects.
* `method::Symbol = :lsmr`: Method to deman regressors. `:lsmr` is akin to conjugate gradient descent.  To use LSMR on multiple cores, use `:lsmr_parallel`. To use LSMR with multiple threads,  use `lsmr_threads`. To use LSMR on GPU, use `lsmr_gpu`(requires `CuArrays`. Use the option `double_precision = false` to use `Float32` on the GPU.).
* `contrasts::Dict = Dict()` An optional Dict of contrast codings for each categorical variable in the `formula`.  Any unspecified variables will have `DummyCoding`.
* `maxiter::Integer = 10000`: Maximum number of iterations
* `double_precision::Bool`: Should the demeaning operation use Float64 rather than Float32? Default to true.
* `tol::Real` Tolerance. Default to 1e-8 if `double_precision = true`, 1e-6 otherwise.



### Details
Models with instruments variables are estimated using 2SLS. `reg` tests for weak instruments by computing the Kleibergen-Paap rk Wald F statistic, a generalization of the Cragg-Donald Wald F statistic for non i.i.d. errors. The statistic is similar to the one returned by the Stata command `ivreg2`.

### Examples
```julia
using RDatasets, FixedEffectModels
df = dataset("plm", "Cigar")
@time reg(df, @formula(Sales ~ Price))
reg(df, @formula(Sales ~ Price + fe(State) + fe(Year)))
reg(df, @formula(Sales ~ NDI + fe(State) + fe(State)&Year))
reg(df, @formula(Sales ~ NDI + fe(State)*Year))
reg(df, @formula(Sales ~ (Price ~ Pimin)))
@time reg(df, @formula(Sales ~ Price), weights = :Pop)
reg(df, @formula(Sales ~ NDI), Vcov.robust()))
reg(df, @formula(Sales ~ NDI), Vcov.cluster(:State)))
reg(df, @formula(Sales ~ NDI), Vcov.cluster(:State , :Year)))
df.Yearc = categoricay(df.Year)
reg(df, @formula(Sales ~ YearC), contrasts = Dict(:YearC => DummyCoding(base = 80)))
```
"""
function reg(df, m::ModelTerm;kwargs...)
    reg(df, m.f; m.dict..., kwargs...)
end

function reg(df, f::FormulaTerm, vcov::Vcov.AbstractVcov = Vcov.simple();
    weights::Union{Symbol, Nothing} = nothing,
    subset::Union{AbstractVector, Nothing} = nothing,
    maxiter::Integer = 10000, contrasts::Dict = Dict{Symbol, Any}(),
    dof_add::Integer = 0,
    save::Union{Bool, Symbol} = false,  method::Symbol = :lsmr, drop_singletons = true, 
    double_precision::Bool = true, tol::Real = double_precision ? 1e-8 : 1e-6,
    feformula::Union{Symbol, Expr, Nothing} = nothing,
    vcovformula::Union{Symbol, Expr, Nothing} = nothing,
    subsetformula::Union{Symbol, Expr, Nothing} = nothing)
    df = DataFrame(df; copycols = false) 

    # to deprecate
    if vcovformula != nothing
        if (vcovformula == :simple) | (vcovformula == :(simple()))
            vcov = Vcov.Simple()
        elseif (vcovformula == :robust) | (vcovformula == :(robust()))
            vcov = Vcov.Robust()
        else
            vcov = Vcov.cluster(StatsModels.termvars(@eval(@formula(0 ~ $(vcovformula.args[2]))))...)
        end
    end
    if subsetformula != nothing
        subset = eval(evaluate_subset(df, subsetformula))
    end

    ##############################################################################
    ##
    ## Parse formula
    ##
    ##############################################################################
    if  (ConstantTerm(0) ∉ eachterm(f.rhs)) & (ConstantTerm(1) ∉ eachterm(f.rhs))
        f = FormulaTerm(f.lhs, tuple(ConstantTerm(1), eachterm(f.rhs)...))
    end
    formula, formula_endo, formula_iv = decompose_iv(f)
    has_iv = formula_iv != nothing
    has_weights = weights != nothing


    ##############################################################################
    ##
    ## Save keyword argument
    ##
    ##############################################################################
    if !(save isa Bool)
        if save ∉ (:residuals, :fe)
            throw("the save keyword argument must be a Bool or a Symbol equal to :residuals or :fe")
        end
    end
    save_residuals = (save == :residuals) | (save == true)


    ##############################################################################
    ##
    ## Construct new dataframe after removing missing values
    ##
    ##############################################################################

    # create a dataframe without missing values & negative weights
    vars = StatsModels.termvars(formula)
    if feformula != nothing # to deprecate
        vars = vcat(vars, StatsModels.termvars(@eval(@formula(0 ~ $(feformula)))))
    end
    iv_vars = Symbol[]
    endo_vars = Symbol[]
    if has_iv
        iv_vars = StatsModels.termvars(formula_iv)
        endo_vars = StatsModels.termvars(formula_endo)
    end
    # create a dataframe without missing values & negative weights
    all_vars = unique(vcat(vars, endo_vars, iv_vars))

    esample = completecases(df, all_vars)
    if has_weights
        esample .&= BitArray(!ismissing(x) & (x > 0) for x in df[!, weights])
    end

    esample .&= completecases(df, vcov)


    if subset != nothing
        if length(subset) != size(df, 1)
            throw("df has $(size(df, 1)) rows but the subset vector has $(length(subset)) elements")
        end
        esample .&= BitArray(!ismissing(x) && x for x in subset)
    end
    fes, ids, formula = parse_fixedeffect(df, formula)
    has_fes = !isempty(fes)
    if feformula != nothing
        has_fes = true
        feformula = @eval(@formula(0 ~ $(feformula)))
        fes, ids = oldparse_fixedeffect(df, feformula)
    end
    if has_fes
        if drop_singletons
            for fe in fes
                drop_singletons!(esample, fe)
            end
        end
    end
    save_fe = (save == :fe) | ((save == true) & has_fes)

    nobs = sum(esample)
    (nobs > 0) || throw("sample is empty")


    # Compute weights
    sqrtw = Ones{Float64}(sum(esample))
    if has_weights
        sqrtw = convert(Vector{Float64}, sqrt.(view(df, esample, weights)))
    end

    all(isfinite, sqrtw) || throw("Weights are not finite")

    # Compute feM, an AbstractFixedEffectSolver
    has_fes_intercept = false
    if has_fes
        # in case some FixedEffect does not have interaction, remove the intercept
        if any(fe.interaction isa Ones for fe in fes)
            formula = FormulaTerm(formula.lhs, tuple(ConstantTerm(0), (t for t in eachterm(formula.rhs) if t!= ConstantTerm(1))...))
            has_fes_intercept = true
        end
        fes = FixedEffect[_subset(fe, esample) for fe in fes]
        feM = AbstractFixedEffectSolver{double_precision ? Float64 : Float32}(fes, sqrtw, Val{method})
    end

    has_intercept = ConstantTerm(1) ∈ eachterm(formula.rhs)
    
    # Compute data for std errors
    vcov_method = Vcov.VcovMethod(view(df, esample, :), vcov)

    ##############################################################################
    ##
    ## Dataframe --> Matrix
    ##
    ##############################################################################
    exo_vars = unique(StatsModels.termvars(formula))
    subdf = StatsModels.columntable(disallowmissing(view(df, esample, exo_vars)))
    formula_schema = apply_schema(formula, schema(formula, subdf, contrasts), StatisticalModel)

    # Obtain y
    # for a Vector{Float64}, conver(Vector{Float64}, y) aliases y
    y = convert(Vector{Float64}, response(formula_schema, subdf))
    all(isfinite, y) || throw("Some observations for the dependent variable are infinite")

    # Obtain X
    Xexo = convert(Matrix{Float64}, modelmatrix(formula_schema, subdf))
    all(isfinite, Xexo) || throw("Some observations for the exogeneous variables are infinite")

    yname, coef_names = coefnames(formula_schema)
    if !(coef_names isa Vector)
        coef_names = typeof(coef_names)[coef_names]
    end


    if has_iv
        subdf = StatsModels.columntable(disallowmissing!(df[esample, endo_vars]))
        formula_endo_schema = apply_schema(formula_endo, schema(formula_endo, subdf, contrasts), StatisticalModel)
        Xendo = convert(Matrix{Float64}, modelmatrix(formula_endo_schema, subdf))
        all(isfinite, Xendo) || throw("Some observations for the endogenous variables are infinite")

        _, coefendo_names = coefnames(formula_endo_schema)
        append!(coef_names, coefendo_names)


        subdf = StatsModels.columntable(disallowmissing!(df[esample, iv_vars]))
        formula_iv_schema = apply_schema(formula_iv, schema(formula_iv, subdf, contrasts), StatisticalModel)
        Z = convert(Matrix{Float64}, modelmatrix(formula_iv_schema, subdf))
        all(isfinite, Z) || throw("Some observations for the instrumental variables are infinite")

        if size(Z, 2) < size(Xendo, 2)
            throw("Model not identified. There must be at least as many ivs as endogeneneous variables")
        end

        # modify formula to use in predict
        formula = FormulaTerm(formula.lhs, (tuple(eachterm(formula.rhs)..., eachterm(formula_endo.rhs)...)))
        formula_schema = apply_schema(formula, schema(formula, StatsModels.columntable(df), contrasts), StatisticalModel)
    end

    # compute tss now before potentially demeaning y
    tss_ = tss(y, has_intercept | has_fes_intercept, sqrtw)


    # create unitilaized 
    iterations, converged, r2_within = nothing, nothing, nothing
    F_kp, p_kp = nothing, nothing

    if has_fes
        # used to compute tss even without save_fe
        if save_fe
            oldy = deepcopy(y)
            if has_iv
                oldX = hcat(Xexo, Xendo)
            else
                oldX = deepcopy(Xexo)
            end
        end

        # initialize iterations and converged
        iterations = Int[]
        convergeds = Bool[]

        y, b, c = solve_residuals!(y, feM; maxiter = maxiter, tol = tol)
        append!(iterations, b)
        append!(convergeds, c)

        Xexo, b, c = solve_residuals!(Xexo, feM; maxiter = maxiter, tol = tol)
        append!(iterations, b)
        append!(convergeds, c)

        if has_iv
            Xendo, b, c = solve_residuals!(Xendo, feM; maxiter = maxiter, tol = tol)
            append!(iterations, b)
            append!(convergeds, c)

            Z, b, c = solve_residuals!(Z, feM; maxiter = maxiter, tol = tol)
            append!(iterations, b)
            append!(convergeds, c)
        end

        iterations = maximum(iterations)
        converged = all(convergeds)
        if converged == false
            @warn "convergence not achieved in $(iterations) iterations; try increasing maxiter or decreasing tol."
        end
    end

    y .= y .* sqrtw
    Xexo .= Xexo .* sqrtw
    if has_iv
        Xendo .= Xendo .* sqrtw
        Z .= Z .* sqrtw
    end
    ##############################################################################
    ##
    ## Get Linearly Independent Components of Matrix
    ##
    ##############################################################################

    # Compute linearly independent columns + create the Xhat matrix
    if has_iv
        # get linearly independent columns
        # note that I do it after residualizing
        baseall = basecol(Z, Xexo, Xendo)
        basecolXexo = baseall[(size(Z, 2)+1):(size(Z, 2) + size(Xexo, 2))]
        basecolXendo = baseall[(size(Z, 2) + size(Xexo, 2) + 1):end]
        Z = getcols(Z, baseall[1:size(Z, 2)])
        Xexo = getcols(Xexo, basecolXexo)
        Xendo = getcols(Xendo, basecolXendo)
        basecoef = vcat(basecolXexo, basecolXendo)

        # Build
        X = hcat(Xexo, Xendo)
        newZ = hcat(Xexo, Z)
        crossz = cholesky!(Symmetric(newZ' * newZ))
        Pi = crossz \ (newZ' * Xendo)
        Xhat = hcat(Xexo, newZ * Pi)

        # prepare residuals used for first stage F statistic
        ## partial out Xendo in place wrt (Xexo, Z)
        Xendo_res = BLAS.gemm!('N', 'N', -1.0, newZ, Pi, 1.0, Xendo)
        ## partial out Z in place wrt Xexo
        Pi2 = cholesky!(Symmetric(Xexo' * Xexo)) \ (Xexo' * Z)
        Z_res = BLAS.gemm!('N', 'N', -1.0, Xexo, Pi2, 1.0, Z)

    else
        # get linearly independent columns
        basecolXexo = basecol(Xexo)
        Xexo = getcols(Xexo, basecolXexo)
        Xhat = Xexo
        X = Xexo
        basecoef = basecolXexo
    end


    ##############################################################################
    ##
    ## Do the regression
    ##
    ##############################################################################

    crossx = cholesky!(Symmetric(Xhat' * Xhat))
    coef = crossx \ (Xhat' * y)
    residuals = y - X * coef

    ##############################################################################
    ##
    ## Optionally save objects in a new dataframe
    ##
    ##############################################################################

    augmentdf = DataFrame()
    if save_residuals
        if nobs < length(esample)
            augmentdf.residuals = Vector{Union{Float64, Missing}}(missing, length(esample))
            augmentdf[esample, :residuals] = residuals ./ sqrtw
        else
            augmentdf[!, :residuals] = residuals ./ sqrtw
        end
    end
    if save_fe
        oldX = getcols(oldX, basecoef)
        newfes, b, c = solve_coefficients!(oldy - oldX * coef, feM; tol = tol, maxiter = maxiter)
        for j in 1:length(fes)
            if nobs < length(esample)
                augmentdf[!, ids[j]] = Vector{Union{Float64, Missing}}(missing, length(esample))
                augmentdf[esample, ids[j]] = newfes[j]
            else
                augmentdf[!, ids[j]] = newfes[j]
            end
        end
    end
    
    ##############################################################################
    ##
    ## Test Statistics
    ##
    ##############################################################################

    # Compute degrees of freedom
    dof_absorb = 0
    if has_fes
        for fe in fes
            # adjust degree of freedom only if fe is not fully nested in a cluster variable:
            if (vcov isa Vcov.Cluster) && any(isnested(fe, v.refs) for v in eachcol(vcov_method.clusters))
                    dof_absorb += 1 # if fe is nested you still lose 1 degree of freedom 
            else
                #only count groups that exists
                dof_absorb += ndistincts(fe)
            end
        end
    end
    dof_residual = max(1, nobs - size(X, 2) - dof_absorb - dof_add)

    # Compute rss, tss, r2, r2 adjusted
    rss = sum(abs2, residuals)
    mss = tss_ - rss
    r2 = 1 - rss / tss_
    adjr2 = 1 - rss / tss_ * (nobs - (has_intercept | has_fes_intercept)) / dof_residual
    if has_fes
        r2_within = 1 - rss / tss(y, (has_intercept | has_fes_intercept), sqrtw)
    end

    # Compute standard error
    vcov_data = Vcov.VcovData(Xhat, crossx, residuals, dof_residual)
    matrix_vcov = Vcov.vcov!(vcov_method, vcov_data)

    # Compute Fstat
    F = Vcov.Fstat(coef, matrix_vcov, has_intercept)

    dof_residual = max(1, Vcov.df_FStat(vcov_method, vcov_data, has_intercept))
    p = ccdf(FDist(max(length(coef) - has_intercept, 1), dof_residual), F)

    # Compute Fstat of First Stage
    if has_iv
        Pip = Pi[(size(Pi, 1) - size(Z_res, 2) + 1):end, :]
        r_kp = Vcov.ranktest!(Xendo_res, Z_res, Pip,
                                  vcov_method, size(X, 2), dof_absorb)
        p_kp = ccdf(Chisq((size(Z_res, 2) - size(Xendo_res, 2) +1 )), r_kp)
        F_kp = r_kp / size(Z_res, 2)
    end

    ##############################################################################
    ##
    ## Return regression result
    ##
    ##############################################################################

    # add omitted variables
    if !all(basecoef)
        newcoef = zeros(length(basecoef))
        newmatrix_vcov = fill(NaN, (length(basecoef), length(basecoef)))
        newindex = [searchsortedfirst(cumsum(basecoef), i) for i in 1:length(coef)]
        for i in eachindex(newindex)
            newcoef[newindex[i]] = coef[i]
            for j in eachindex(newindex)
                newmatrix_vcov[newindex[i], newindex[j]] = matrix_vcov[i, j]
            end
        end
        coef = newcoef
        matrix_vcov = newmatrix_vcov
    end

    return FixedEffectModel(coef, matrix_vcov, vcov, esample, augmentdf,
                            coef_names, yname, f, formula_schema, nobs, dof_residual,
                            rss, tss_, r2, adjr2, F, p,
                            iterations, converged, r2_within, 
                            F_kp, p_kp)
end
