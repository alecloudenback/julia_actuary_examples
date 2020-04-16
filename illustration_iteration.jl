# https://julialang.zulipchat.com/#narrow/stream/225542-helpdesk/topic/Iterators/near/193978207

# using IterTools
using Dates
using ActuaryUtilities
using DayCounts
using Parameters
using DataFrames
using MortalityTables
using Setfield

tbls = MortalityTables.tables()

@with_kw struct DateParameters
    periodicity = Month(1)
    start_date = today()
    convention = DayCounts.Actual365Fixed()  # e.g. DayCounts.jl 30/360, Actual365, etc
end

@with_kw struct Plan
    # credit_rate = 0.05
    coi = tbls["2001 VBT Select and Ultimate - Male Nonsmoker, ANB"]
    maturity_age
    iter_func
end

struct Projection
    params
    plan
    policy
    date_params::DateParameters
end

# plan is the functional definition for the policy
# return the set of values in a tuple that you want to keep track of 

function basic_plan(proj,prior_values)
    date = prior_values.date + proj.date_params.periodicity
    dur = duration(proj.policy.issue_date,date)
    age = proj.policy.issue_age + dur - 1
    av = prior_values.av
    time_since_last_period = DayCounts.yearfrac(
                                prior_values.date,
                                date,
                                proj.date_params.convention
                                )

    ## premiums
    if month(date) == month(proj.policy.issue_date)
        prem = proj.policy.premium
    else 
        prem = 0.0
    end

    av += prem

    ## cost of insurance
    
    coi_rate = q( proj.plan.coi.select,
                  proj.policy.issue_age,
                  dur) 


    coi = (proj.policy.spec_amt - av) * coi_rate * time_since_last_period

    av -= coi
    
    ## interest
    int_factor = (1 + proj.params.interest_rate) ^ time_since_last_period

    interest = av * int_factor
    av += int_factor





    return (period = prior_values.period + 1,
            date = date,
            attained_age = age,
            prem = prem,
            coi = coi,
            int_credited = interest,
            av = av,
            islapsed = (av <= 0.0) | ( age + dur > 120)
    )
end
function basic_plan(proj)
    t0 = proj.date_params.start_date - proj.date_params.periodicity
    return (period = 0,
            date = t0,
            attained_age = proj.policy.issue_age,
            prem = 0.0,
            coi = 0.0,
            int_credited = 0.0,
            av = 0.0,
            islapsed = false)
end

function Base.iterate(proj::Projection) 
    current_values = proj.plan.iter_func(proj)
    return current_values, proj.plan.iter_func(proj,current_values)
end

function Base.iterate(proj::Projection,current_values)
    if current_values.attained_age == proj.plan.maturity_age - 1
        return nothing
    else
        return current_values, proj.plan.iter_func(proj,current_values)
    end
end

Base.IteratorSize(t::Projection) = Base.SizeUnknown()

p_iter = Projection(
    # run parameters
    (interest_rate = 0.05,),

    # Plan Parameters
    Plan(
        tbls["2001 VBT Select and Ultimate - Male Nonsmoker, ANB"],
        121,
        basic_plan

        ),

    # policy parameters (not yet factored out into struct)
    (issue_date = today(),
    issue_age = 40,
    spec_amt = 1.0e6,
    premium = 5000.0),

    # Date Parameters
    DateParameters()


)

# run the projection
[x for x in p_iter] |> DataFrame

# return the account value at the end of the specified age
function av(proj,prem,age)
    p = @set proj.policy.premium = prem
    illus = [x for x in p if x.attained_age == age]
    if size(illus,1) >= 1
        return illus[end].av
    else
        return 0.0
    end
end

# solve for the required premium to get to the given age
using Optim

optimize(x -> sum(av(p_iter,x,100) .^ 2),0.0,1.0e6)