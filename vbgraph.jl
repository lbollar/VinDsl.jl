# let's define some types
using Distributions

"""
A Variational Bayesian Model. Models are defined by 
bipartite graphs in which factors defining terms in the variational
objective are connected to nodes defining variables.
"""
abstract VBModel  

"Defines a factor, a term in the variational objective."
abstract Factor

"Defines a node (variable) in the model."
abstract Node

"Node corresponding to a collection of random variables."
type RandomNode{D <: Distribution, N} <: Node
    data::Array{D, N}
    factors::Vector{Factor}
end

RandomNode{D <: Distribution}(d::Type{D}, pars...) = RandomNode(map(d, pars...), Factor[])

# define an expectation method on Nodes
"Calculates the expected value of a Node x."
E(x::Node) = x
E(x::RandomNode) = map(mean, x.data)