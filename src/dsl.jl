# code to handle the domain-specific language used to define models

"""
Create a node using formula syntax. E.g.,
x[i, j, k] ~ Normal(μ, σ)
z ~ Gamma(a, b)
y[a, b] ~ Const(Y)  (for a constant node)
"""
macro ~(varex, distex)
    if isa(varex, Symbol)
        name = varex
        inds = :(Symbol[])
    elseif varex.head == :ref
        name = varex.args[1]
        inds = Symbol[varex.args[2:end]...]
    end
    qname = Expr(:quote, name)

    if distex.head == :call
        if distex.args[1] == :Const
            constr = :ConstantNode
            out = :($name = $constr($qname, $inds, $(distex.args[2])))
        else
            constr = :RandomNode
            dist = distex.args[1]
            distargs = distex.args[2:end]
            out = :($name = $constr($qname, $inds, $dist, $(distargs...)))
        end
    end
    esc(out)
end

"""
Define a node by an expression involving other nodes.
"""
macro exprnode(name, ex)
    nodelist = collect(setdiff(get_all_syms(ex), get_all_inds(ex)))
    qname = Expr(:quote, name)
    qex = Expr(:quote, ex)
    Eex = :(E($ex))
    Vex = :(V($ex))
    Cex = :(C($ex))
    Hex = :(H($ex))
    out_expr = quote
        $name = ExprNode($qname, $qex, Node[$(nodelist...)])

        # need to fully qualify E, else running @exprnode
        # outside the module will not extend, but overwrite
        VinDsl.E(d::ExprDist{Val{$qname}}) = @wrapvars $nodelist (@simplify $Eex) nodeextract d
        VinDsl.V(d::ExprDist{Val{$qname}}) = @wrapvars $nodelist (@simplify $Vex) nodeextract d
        VinDsl.C(d::ExprDist{Val{$qname}}) = @wrapvars $nodelist (@simplify $Cex) nodeextract d
        VinDsl.H(d::ExprDist{Val{$qname}}) = @wrapvars $nodelist (@simplify $Hex) nodeextract d
    end
    esc(out_expr)
end

###################################################
# Macro to define a factor
###################################################
macro deffactor(typename, vars, valexpr)
    varlist = [:($v::Node) for v in vars.args]
    varblock = Expr(:block, varlist...)
    value_formula = Expr(:quote, valexpr)

    ex = quote
        immutable ($typename){N} <: Factor{N}
            $varblock
            inds::FactorInds
            namemap::Dict{Symbol, Symbol}
        end

        value{N}(::Type{($typename){N}}) = $value_formula
    end
    esc(ex)
end

###################################################
# Macro to instantiate a factor using ~
###################################################
macro pmodel(ex)
    body = _pmodel(ex)
    out = quote
        pmodel_factors = Factor[]
        $body
    end
    esc(out)
end

function _pmodel(ex)
    # if we have a ~ expression, replace with an @factor
    if ex.head == :macrocall && ex.args[1] == Symbol("@~")
        lhs = ex.args[2]
        rhs = ex.args[3]
        factorname = Symbol("Log", rhs.args[1], "Factor")
        out = :(push!(pmodel_factors, @factor $factorname $lhs $(rhs.args[2:end]...)))
    else  # recursively parse
        out = copy(ex)
        for i in eachindex(out.args)
            out.args[i] = isa(out.args[i], Expr) ? _pmodel(out.args[i]) : out.args[i]
        end
    end
    out
end

######### macros/functions to generalize expectations of expressions ##########
macro simplify(ex)
    esc(_simplify(ex))
end

# define some useful typealiases: Expectation-like functions, linear
# Expectation-like functions, and linear operators
valify(s::Symbol) = :(Type{Val{$(Expr(:quote, s))}})

linops = [:+, :-, :.+, :.*]
eval(:(typealias LinearOpType Union{$([valify(op) for op in linops]...)}))

elike_funs = [:E, :V, :C, :H, :Elog, :ElogB, :Eloggamma, :Elogdet]
eval(:(typealias Elike Union{$([valify(fn) for fn in elike_funs]...)}))
eval(:(typealias Elin Union{$([valify(fn) for fn in elike_funs[1:3]]...)}))

commuting_operators = [Symbol("'")]
commuting_fns = [:sum, :prod, :dot]
eval(:(typealias Commuters Union{$([valify(fn) for fn in commuting_fns]...)}))

#=
_simplify expands the expectations in an arbitrary expression
_simplify_and_wrap expands the expression inside some expectation function
(E, V, C, etc.) and then simplifies the expectation of that expression
=#
_simplify(x) = x  # all terminal expressions not otherwise specified
_simplify(x::Symbol) = x
function _simplify(ex::Expr)
    if ex.head == :call
        out_expr = _simplify_call(Val{ex.args[1]}, ex.args[2:end])
    else
        out_expr = _simplify_inside(Val{ex.head}, ex.args)
    end
    out_expr
end

function _simplify_inside{F}(::Type{Val{F}}, args)
    newargs = [_simplify(a) for a in args]
    Expr(F, newargs...)
end

function _simplify_call{F}(::Type{Val{F}}, args)
    if (length(args) == 1) && isa(args[1], Expr) && (args[1].head == :call)
        ex = args[1]
        out = _simplify_compose(Val{F}, Val{ex.args[1]}, ex.args[2:end])
    else
        newargs = [_simplify(a) for a in args]
        out = :($F($(newargs...)))
    end
    out
end

_simplify_call(Eopval::Elike, x) = :($(Eopval.parameters[1])($x))
function _simplify_call(Eopval::Elike, ex::Expr)
    Eop = Eopval.parameters[1]
    if ex.head == :call
        out = _simplify_compose(Eopval, Val{ex.args[1]}, ex.args[2:end])
    elseif ex.head in commuting_operators
        out = Expr(ex.head, _simplify_call(Eopval, ex.args))
    else
        out = :($Eop($ex))
    end
    out
end
function _simplify_call(Eopval::Elike, args::Vector)
    Eop = Eopval.parameters[1]
    if length(args) == 1
        out = _simplify_call(Eopval, args[1])
    else
        newargs = map(_simplify, args)
        out = :($Eop($(newargs...)))
    end
    out
end
_simplify_call(::Type{Val{:E}}, x::Number) = x

function _simplify_compose{F, G}(::Type{Val{F}}, ::Type{Val{G}}, args)
    simplified_exprs = map(_simplify, args)
    :($F($G($(simplified_exprs...))))
end

function _simplify_compose(::Type{Val{:E}}, ::Type{Val{:E}}, args)
    _simplify_call(Val{:E}, args)
end
function _simplify_compose(Eopval::Elin, opval::LinearOpType, args)
    op = opval.parameters[1]
    Eop = Eopval.parameters[1]
    newargs = [:($Eop($a)) for a in args]
    _simplify_call(opval, newargs)
end
function _simplify_compose(Eopval::Elin, opval::Type{Val{:sum}}, args)
    op = opval.parameters[1]
    Eop = Eopval.parameters[1]
    sub_ex = _simplify(:($Eop($(args...))))
    _simplify(:($op($sub_ex)))
end
function _simplify_compose(Eopval::Type{Val{:E}}, opval::Type{Val{:prod}}, args)
    op = opval.parameters[1]
    Eop = Eopval.parameters[1]
    sub_ex = _simplify(:($Eop($(args...))))
    _simplify(:($op($sub_ex)))
end
function _simplify_compose(::Type{Val{:E}}, opval::Type{Val{:^}}, args)
    x, p = args
    if p == 2
        out = _simplify(:(V($x) + E($x)^2))
    else
        out = :(E($x^$p))
    end
    out
end
function _simplify_compose(::Type{Val{:E}}, opval::Type{Val{:dot}}, args)
    x, y = args
    Ex = _simplify(:(E($x)))
    Ey = _simplify(:(E($y)))
    :(dot($Ex, $Ey))
end
function _simplify_compose(::Type{Val{:E}}, opval::Type{Val{:log}}, args)
    _simplify_call(Val{:Elog}, args)
end

function _simplify_compose(::Type{Val{:E}}, opval::Type{Val{:*}}, args)
    op = opval.parameters[1]
    # symbol factors
    symsets = [setdiff(get_all_syms(a), get_all_inds(a)) for a in args]

    # are symbols repeated across arguments?
    pairwise_intersections = map(x -> intersect(x[1], x[2]), combinations(symsets, 2))
    repeats = any(x -> !isempty(x), pairwise_intersections)

    if !repeats
        simplified_exprs = [_simplify(:(E($a))) for a in args]
        out = :($op($(simplified_exprs...)))
    else
        # some variables are repeated, and we can't assume * is
        # commutative, so don't rearrange factors

        repeated_syms = union(pairwise_intersections...)

        # which positions contain repeated symbols?
        syminds = []
        for i in eachindex(args)
            if !isempty(intersect(symsets[i], repeated_syms))
                push!(syminds, i)
            end
        end

        # check to see whether we can do any rewriting:
        if (syminds[1] == 1 && syminds[end] == length(args))
            # first and last expressions contain shared symbols:
            # no rewriting possible
            # wrap in E(⋅) and output
            out = :(E($op($(args...))))
        else
            # we can rewrite arguments of Expr
            out = Expr(:call, op)

            # expand everything up to first repeated symbol
            if syminds[1] > 1
                for a in args[1:(syminds[1] - 1)]
                    push!(out.args, _simplify(:(E($a))))
                end
            end

            # clump everything between repeated symbols together
            base_expr = Expr(:call, op, args[syminds[1]:syminds[end]]...)
            E_expr = Expr(:call, :E, base_expr)
            push!(out.args, E_expr)

            # expand everything after last repeated symbol
            if syminds[end] < length(args)
                for a in args[(syminds[end] + 1):end]
                    push!(out.args, _simplify(:(E($a))))
                end
            end
        end
    end
    out
end

function _simplify_compose(::Type{Val{:V}}, opval::Type{Val{:dot}}, args)
    op = opval.parameters[1]
    x, y = args
    _simplify(:(sum(C($x) .* C($y)) + E($y)' * C($x) * E($y) + E($x)' * C($y) * E($x)))
end

function _simplify_compose(::Type{Val{:V}}, opval::Type{Val{:*}}, args)
    op = opval.parameters[1]
    squares = Expr(:call, op, [:($a^2) for a in args]...)
    means = Expr(:call, op, [:(E($a)^2) for a in args]...)
    _simplify(:(E($squares) - $means))
end
