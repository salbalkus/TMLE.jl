###############################################################################
## General Utilities
###############################################################################

logit(X) = log.(X ./ (1 .- X))
logit(X::AbstractNode) = node(x->logit(x), X)

expit(X) = 1 ./ (1 .+ exp.(-X))
expit(X::AbstractNode) = node(x->expit(x), X)

influencecurve(covariate, y, observed_fluct, ct_fluct, estimate) = 
    covariate .* (float(y) .- observed_fluct) .+ ct_fluct .- estimate

standarderror(inf_curve) = sqrt(var(inf_curve)/nrows(inf_curve))


"""
Hack into GLM to compute deviance on y a real
"""
function GLM.devresid(::Bernoulli, y::Vector{<:Real}, μ::Real)
    return -2*(y*log(μ) + (1-y)*log1p(-μ))
end

"""
Remove default check for y to be binary
"""
GLM.checky(y, d::Bernoulli) = nothing

"""

Let's default to no warnings for now.
"""
MLJBase.check(model::TMLEstimator, args... ; full=false) = true

Base.merge(ndt₁::AbstractNode, ndt₂::AbstractNode) = 
    node((ndt₁, ndt₂) -> merge(ndt₁, ndt₂), ndt₁, ndt₂)

fluctuation_input(covariate, offset) = (covariate=covariate, offset=offset)
fluctuation_input(covariate::AbstractNode, offset::AbstractNode) =
    node((c, o) -> fluctuation_input(c, o), covariate, offset)

"""

Adapts the type of the treatment variable passed to the G learner
"""
adapt(T::NamedTuple{<:Any, NTuple{1, Z}}) where Z = T[1]
adapt(T) = T
adapt(T::AbstractNode) = node(adapt, T)

###############################################################################
## Reporting utilities
###############################################################################

function queryreport(qr; tail=:both)

    inf_curve, tmle_estimate, initial_estimate = qr
    stderr = standarderror(inf_curve) 
    pval = pvalue(tmle_estimate, stderr, tail=tail)
    confint = confinterval(tmle_estimate, stderr)
    mean_inf_curve = mean(inf_curve)

    return (pvalue=pval, confint=confint, estimate=tmle_estimate, stderror=stderr, initial_estimate=initial_estimate, mean_inf_curve=mean_inf_curve)
end

    """
    pvalue(m::Machine{TMLEstimator})

Computes the p-value associated with the estimated quantity.
"""
function pvalue(estimate, stderror; tail=:both)
    x = estimate/stderror

    dist = Normal(0, 1)
    if tail == :both
        min(2 * min(cdf(dist, x), ccdf(dist, x)), 1.0)
    elseif tail == :left
        cdf(dist, x)
    elseif tail == :right
        ccdf(dist, x)
    else
        throw(ArgumentError("tail=$(tail) is invalid"))
    end
end

"""
    confinterval(m::Machine{TMLEstimator})

Provides a 95% confidence interval for the true quantity of interest.
"""
function confinterval(estimate, stderror)
    return (estimate - 1.96stderror, estimate + 1.96stderror)
end

###############################################################################
## Interactions Generation
###############################################################################

"""
    interaction_combinations(query::NamedTuple{names,})
Returns a generator over the different combinations of interactions that
can be built from a query.
"""
function interaction_combinations(query::NamedTuple{names,}) where names
    return (NamedTuple{names}(query) for query in Iterators.product(query...))
end


"""
    indicator_fns(query::NamedTuple{names,})

Implements the (-1)^{n-j} formula representing the cross-value of
indicator functions,  where:
    - n is the order of interaction considered
    - j is the number of treatment variables different from the "case" value
"""
function indicator_fns(query::NamedTuple{nms,}) where nms
    case = NamedTuple{nms}([v[1] for v in query])
    interactionorder = length(query)
    return Dict(q => (-1)^(interactionorder - sum(q[key] == case[key] for key in nms)) 
                for q in interaction_combinations(query))
end


###############################################################################
## Offset
###############################################################################

target_prob(y) = y.prob_given_ref[2]
target_prob(y::AbstractNode) = node(y->target_prob(y), y)


compute_offset(Q̅mach::Machine{<:Deterministic}, X) = expected_value(Q̅mach, X)
function compute_offset(Q̅mach::Machine{<:Probabilistic}, X)
    expectation = expected_value(Q̅mach, X)
    return logit(expectation)
end


expected_value(Q̅mach::Machine{<:Deterministic}, X) = MLJ.predict(Q̅mach, X)
function expected_value(Q̅mach::Machine{<:Probabilistic}, X) 
    # The machine is an estimate of a probability distribution
    # In the binary case, the expectation is assumed to be the probability of the second class
    ŷ = MLJ.predict(Q̅mach, X)
    return target_prob(ŷ)
end

###############################################################################
## Covariate
###############################################################################

function indicator_values(indicators, T)
    covariate = zeros(nrows(T))
    for (i, row) in enumerate(Tables.namedtupleiterator(T))
        if haskey(indicators, row)
            covariate[i] = indicators[row]
        end
    end
    covariate
end
indicator_values(indicators, T::AbstractNode) = 
    node(t -> indicator_values(indicators, t), T)


plateau_likelihood(likelihood, threshold) = max.(threshold, likelihood)
plateau_likelihood(likelihood::AbstractNode, threshold) = 
    node(l -> plateau_likelihood(l, threshold), likelihood)

elemwise_divide(x, y) = x ./ y
elemwise_divide(x::AbstractNode, y::AbstractNode) = 
    node((x, y) -> elemwise_divide(x,y), x, y)

"""
For each data point, computes: (-1)^(interaction-oder - j)
Where j is the number of treatments different from the reference in the query.
"""
function compute_covariate(Gmach::Machine, W, T, indicators; threshold=0.005)
    # Compute the indicator value
    indic_vals = indicator_values(indicators, T)

    # Compute density and truncate
    likelihood = density(Gmach, W, T)

    likelihood = plateau_likelihood(likelihood, threshold)
    
    return elemwise_divide(indic_vals, likelihood)
end


###############################################################################
## Fluctuation
###############################################################################

function counterfactualTreatment(vals, T)
    names = keys(vals)
    n = nrows(T)
    NamedTuple{names}(
            [categorical(repeat([vals[name]], n), levels=levels(Tables.getcolumn(T, name)))
                            for name in names])
end


function compute_fluctuation(Fmach::Machine, 
                             Q̅mach::Machine, 
                             Gmach::Machine, 
                             indicators,
                             W, 
                             T,
                             X; 
                             threshold=0.005)
    offset = compute_offset(Q̅mach, X)
    covariate = compute_covariate(Gmach, W, T, indicators; 
                                    threshold=threshold)
    Xfluct = fluctuation_input(covariate, offset)
    return  MLJ.predict_mean(Fmach, Xfluct)
end

###############################################################################
## Report
###############################################################################

function estimation_report(Fmach::Machine,
    Q̅mach::Machine,
    Gmach::Machine,
    Hmach::Machine,
    W::AbstractNode,
    T::AbstractNode,
    observed_fluct::AbstractNode,
    ys::AbstractNode,
    covariate::AbstractNode,
    indicators,
    threshold)
    node((w, t, o, y, c) -> estimation_report(Fmach, Q̅mach, Gmach, Hmach, w, t, o, y, c, indicators, threshold), 
                                W, T, observed_fluct, ys, covariate)
end

"""

For a given query, identified by `indicators`, reports the different quantities of
interest. An important intermediate quantity is obtained by aggregation of 
E[Y|T, W] evaluated at the various counterfactual values of the treatment.
For instance, if the order of Interaction is 2 with binary variables, this is computed as:

AggregatedCounterfactual = Fluctuation(t₁=1, t₂=1, W=w) - Fluctuation(t₁=1, t₂=0, W=w)
                - Fluctuation(t₁=0, t₂=1, W=w) + Fluctuation(t₁=0, t₂=0, W=w)
"""
function estimation_report(Fmach::Machine,
                            Q̅mach::Machine,
                            Gmach::Machine,
                            Hmach::Machine,
                            W,
                            T,
                            observed_fluct,
                            ys,
                            covariate,
                            indicators, 
                            threshold)

    tmle_ct_agg = zeros(nrows(T))
    initial_ct_agg = zeros(nrows(T))
    for (vals, sign) in indicators 
        counterfactualT = counterfactualTreatment(vals, T)
        Thot = transform(Hmach, counterfactualT)
        X = merge(Thot, W)
        initial_ct_agg += sign*expected_value(Q̅mach, X)
        tmle_ct_agg += sign*compute_fluctuation(Fmach, 
                    Q̅mach, 
                    Gmach,
                    indicators,
                    W, 
                    counterfactualT,
                    X; 
                    threshold=threshold)
    end

    initial_estimate = mean(initial_ct_agg)
    tmle_estimate = mean(tmle_ct_agg)
    inf_curve = influencecurve(covariate, ys, observed_fluct, tmle_ct_agg, tmle_estimate)

    return inf_curve, tmle_estimate, initial_estimate
end
