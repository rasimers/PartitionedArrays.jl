
function get_local_values end

function get_own_values end

function get_ghost_values end

function allocate_local_values(a,::Type{T},indices) where T
    similar(a,T,get_n_local(indices))
end

function allocate_local_values(::Type{V},indices) where V
    similar(V,get_n_local(indices))
end

function get_local_values(values,indices)
    values
end

function get_own_values(values,indices)
    own_to_local = get_own_to_local(indices)
    view(values,own_to_local)
end

function get_ghost_values(values,indices)
    ghost_to_local = get_ghost_to_local(indices)
    view(values,ghost_to_local)
end

struct OwnAndGhostValues{A,C,T} <: AbstractVector{T}
    own_values::A
    ghost_values::A
    perm::C
    function OwnAndGhostValues{A,C}(own_values,ghost_values,perm) where {A,C}
        T = eltype(A)
        new{A,C,T}(
          convert(A,own_values),
          convert(A,ghost_values),
          convert(C,perm))
    end
end
function OwnAndGhostValues{A}(own_values,ghost_values,perm) where A
    C = typeof(perm)
    OwnAndGhostValues{A,C}(own_values,ghost_values,perm)
end
function OwnAndGhostValues(own_values::A,ghost_values::A,perm) where A
    OwnAndGhostValues{A}(own_values,ghost_values,perm)
end
Base.IndexStyle(::Type{<:OwnAndGhostValues}) = IndexLinear()
Base.size(a::OwnAndGhostValues) = (length(a.own_values)+length(a.ghost_values),)
function Base.getindex(a::OwnAndGhostValues,local_id::Int)
    n_own = length(a.own_values)
    j = a.perm[local_id]
    if j > n_own
        a.ghost_values[j-n_own]
    else
        a.own_values[j]
    end
end
function Base.setindex!(a::OwnAndGhostValues,v,local_id::Int)
    n_own = length(a.own_values)
    j = a.perm[local_id]
    if j > n_own
        a.ghost_values[j-n_own] = v
    else
        a.own_values[j] = v
    end
    v
end

function get_own_values(values::OwnAndGhostValues,indices)
    values.own_values
end

function get_ghost_values(values::OwnAndGhostValues,indices)
    values.ghost_values
end

function allocate_local_values(values::OwnAndGhostValues,::Type{T},indices) where T
    n_own = get_n_own(indices)
    n_ghost = get_n_ghost(indices)
    own_values = similar(values.own_values,T,n_own)
    ghost_values = similar(values.ghost_values,T,n_ghost)
    perm = get_permutation(indices)
    OwnAndGhostValues(own_values,ghost_values,perm)
end

function allocate_local_values(::Type{<:OwnAndGhostValues{A}},indices) where {A}
    n_own = get_n_own(indices)
    n_ghost = get_n_ghost(indices)
    own_values = similar(A,n_own)
    ghost_values = similar(A,n_ghost)
    perm = get_permutation(indices)
    OwnAndGhostValues{A}(own_values,ghost_values,perm)
end

struct PVector{V,A,B,T} <: AbstractVector{T}
    values::A
    rows::B
    function PVector(values,rows::PRange)
        V = eltype(values)
        T = eltype(V)
        A = typeof(values)
        B = typeof(rows)
        new{V,A,B,T}(values,rows)
    end
end

function Base.show(io::IO,k::MIME"text/plain",data::PVector)
    println(io,typeof(data)," on $(length(data.values)) parts")
end

function get_local_values(a::PVector)
    map(get_local_values,a.values,rows.indices)
end

function get_own_values(a::PVector)
    map(get_own_values,a.values,rows.indices)
end

function get_ghost_values(a::PVector)
    map(get_ghost_values,a.values,rows.indices)
end

Base.size(a::PVector) = (length(a.rows),)
Base.axes(a::PVector) = (a.rows,)
Base.IndexStyle(::Type{<:PVector}) = IndexLinear()
function Base.getindex(a::PVector,gid::Int)
    scalar_indexing_action(a)
end
function Base.setindex(a::PVector,v,gid::Int)
    scalar_indexing_action(a)
end

function assemble!(a::PVector)
    assemble!(+,a)
end

function assemble!(o,a::PVector)
    t = assemble!(o,a.values,a.assembler)
    @async begin
        wait(t)
        a
    end
end

function consistent!(a::PVector)
    insert(a,b) = b
    t = assemble!(insert,a.values,reverse(a.assembler))
    @async begin
        wait(t)
        a
    end
end

function Base.similar(a::PVector,::Type{T},inds::Tuple{<:PRange}) where T
    rows = inds[1]
    values = map(a.values,rows.indices) do values, indices
        allocate_local_values(values,T,indices)
    end
    PVector(values,rows)
end

function Base.similar(::Type{<:PVector{V}},inds::Tuple{<:PRange}) where V
  rows = inds[1]
  values = map(rows.indices) do indices
      allocate_local_values(V,indices)
  end
  PVector(values,rows)
end

function Base.copy!(a::PVector,b::PVector)
    @assert length(a) == length(b)
    copyto!(a,b)
end

function Base.copyto!(a::PVector,b::PVector)
    if a.rows.indices === b.rows.indices
        map(copy!,a.values,b.values)
    elseif matching_own_indices(a,b)
        map(copy!,get_own_values(a),get_own_values(b))
    else
        error("Trying to copy a PVector into another one with a different data layout. This case is not implemented yet. It would require communications.")
    end
    a
end

function Base.fill!(a::PVector,v)
    map(a.values) do values
        fill!(values,v)
    end
    a
end

function pvector(f,rows)
    values = map(rows.indices) do indices
        f(indices)
    end
    PVector(values,rows)
end

PVector(::UndefInitializer,rows::PRange) = PVector{Vector{Float64}}(undef,rows)
PVector{V}(::UndefInitializer,rows::PRange) where V = pvector(indices->allocate_local_values(V,indices),rows)
pfill(v,rows) = pvector(indices->fill(v,get_n_local(indices)),rows)
pzeros(rows) = pzeros(Float64,rows)
pzeros(::Type{T},rows) where T = pvector(indices->zeros(T,get_n_local(indices)),rows)
pones(rows) = pones(Float64,rows)
pones(::Type{T},rows) where T = pvector(indices->ones(T,get_n_local(indices)),rows)
prand(rows) = pvector(indices->rand(get_n_local(indices)),rows)
prand(s,rows) = pvector(indices->rand(S,get_n_local(indices)),rows)
prand(rng,s,rows) = pvector(indices->rand(rng,S,get_n_local(indices)),rows)
prandn(rows) = pvector(indices->randn(get_n_local(indices)),rows)
prandn(s,rows) = pvector(indices->randn(S,get_n_local(indices)),rows)
prandn(rng,s,rows) = pvector(indices->randn(rng,S,get_n_local(indices)),rows)

function Base.:(==)(a::PVector,b::PVector)
    length(a) == length(b) &&
    length(a.values) == length(b.values) &&
    reduce(&,map(==,get_own_values(a),get_own_values(b)),init=true)
end

function Base.any(f::Function,x::PVector)
    partials = map(get_own_values(f)) do o
        any(f,o)
    end
    reduce(|,partials,init=false)
end

function Base.all(f::Function,x::PVector)
    partials = map(get_own_values(x)) do o
        all(f,o)
    end
    reduce(&,partials,init=true)
end

Base.maximum(x::PVector) = maximum(identity,x)
function Base.maximum(f::Function,x::PVector)
    partials = map(get_own_values(x)) do o
        maximum(f,o,init=typemin(eltype(x)))
    end
    reduce(max,partials,init=typemin(eltype(x)))
end

Base.minimum(x::PVector) = minimum(identity,x)
function Base.minimum(f::Function,x::PVector)
    partials = map(get_own_values(x)) do o
        minimum(f,o,init=typemax(eltype(x)))
    end
    reduce(min,partials,init=typemax(eltype(x)))
end

function Base.:*(a::Number,b::PVector)
    values = map(b.values) do values
        a*values
    end
    PVector(values,b.rows)
end

function Base.:*(b::PVector,a::Number)
    a*b
end

function Base.:/(b::PVector,a::Number)
    (1/a)*b
end

for op in (:+,:-)
    @eval begin
        function Base.$op(a::PVector)
            values = map($op,a.values)
            PVector(values,a.rows)
        end
        function Base.$op(a::PVector,b::PVector)
            $op.(a,b)
        end
    end
end

function neutral_element end
neutral_element(::typeof(+),::Type{T}) where T = zero(T)
neutral_element(::typeof(&),::Type) = true
neutral_element(::typeof(|),::Type) = false
neutral_element(::typeof(min),::Type{T}) where T = typemax(T)
neutral_element(::typeof(max),::Type{T}) where T = typemin(T)

function Base.reduce(op,a::PVector;neutral=neutral_element(op,eltype(a)),kwargs...)
    b = map(get_own_values(a)) do a
        reduce(op,a,init=neutral)
    end
    reduce(op,b;kwargs...)
end

function Base.sum(a::PVector)
  reduce(+,a,init=zero(eltype(a)))
end

function LinearAlgebra.dot(a::PVector,b::PVector)
    c = map(dot,get_own_values(a),get_own_values(b))
    sum(c)
end

function LinearAlgebra.rmul!(a::PVector,v::Number)
    map(a.values) do l
        rmul!(l,v)
    end
    a
end

function LinearAlgebra.norm(a::PVector,p::Real=2)
    contibs = map(get_own_values(a)) do oid_to_value
        norm(oid_to_value,p)^p
    end
    reduce(+,contibs;init=zero(eltype(contibs)))^(1/p)
end

struct PBroadcasted{A,B,C}
    owned_values::A
    ghost_values::B
    rows::C
end
get_own_values(a::PBroadcasted) = a.own_values
get_ghost_values(a::PBroadcasted) = a.ghost_values

function Base.broadcasted(f, args::Union{PVector,PBroadcasted}...)
    a1 = first(args)
    @boundscheck @assert all(ai->matching_own_indices(ai.rows,a1.rows),args)
    owned_values_in = map(get_own_values,args)
    owned_values = map((largs...)->Base.broadcasted(f,largs...),owned_values_in...)
    if all(ai->ai.rows===a1.rows,args) && !any(ai->ai.ghost_values===nothing,args)
        ghost_values_in = map(get_ghost_values,args)
        ghost_values = map((largs...)->Base.broadcasted(f,largs...),ghost_values_in...)
    else
        ghost_values = nothing
    end
    PBroadcasted(owned_values,ghost_values,a1.rows)
end

function Base.broadcasted( f, a::Number, b::Union{PVector,PBroadcasted})
    owned_values = map(b->Base.broadcasted(f,a,b),get_own_values(b))
    if b.ghost_values !== nothing
        ghost_values = map(b->Base.broadcasted(f,a,b),get_ghost_values(b))
    else
        ghost_values = nothing
    end
    PBroadcasted(owned_values,ghost_values,b.rows)
end

function Base.broadcasted( f, a::Union{PVector,PBroadcasted}, b::Number)
    owned_values = map(a->Base.broadcasted(f,a,b),get_own_values(a))
    if a.ghost_values !== nothing
        ghost_values = map(a->Base.broadcasted(f,a,b),get_ghost_values(a))
    else
        ghost_values = nothing
    end
    PBroadcasted(owned_values,ghost_values,a.rows)
end

function Base.materialize(b::PBroadcasted)
    T = eltype(eltype(b.own_values))
    a = PVector{Vector{T}}(undef,b.rows)
    materialize!(a,b)
    a
end

function Base.materialize!(a::PVector,b::PBroadcasted)
    map(Base.materialize!,get_own_values(a),get_own_values(b))
    if b.ghost_values !== nothing && a.rows === b.rows
        map(Base.materialize!,get_ghost_values(a),get_ghost_values(b))
    end
    a
end

for M in Distances.metrics
    @eval begin
        function (dist::$M)(a::PVector,b::PVector)
            if Distances.parameters(dist) !== nothing
                error("Only distances without parameters are implemented at this moment")
            end
            partials = map(get_own_values(a),get_own_values(b)) do a,b
                @boundscheck if length(a) != length(b)
                    throw(DimensionMismatch("first array has length $(length(a)) which does not match the length of the second, $(length(b))."))
                end
                if length(a) == 0
                    return zero(Distances.result_type(d, a, b))
                end
                @inbounds begin
                    s = Distances.eval_start(d, a, b)
                    if (IndexStyle(a, b) === IndexLinear() && eachindex(a) == eachindex(b)) || axes(a) == axes(b)
                        @simd for I in eachindex(a, b)
                            ai = a[I]
                            bi = b[I]
                            s = Distances.eval_reduce(d, s, Distances.eval_op(d, ai, bi))
                        end
                    else
                        for (ai, bi) in zip(a, b)
                            s = Distances.eval_reduce(d, s, Distances.eval_op(d, ai, bi))
                        end
                    end
                    return s
                end
            end
            s = reduce((i,j)->Distances.eval_reduce(d,i,j),
                       partials,
                       init=Distances.eval_start(d, a, b))
            Distances.eval_end(d,s)
        end
    end
end

function pvector_coo!(I,V,rows;kwargs...)
    pvector_coo(+,Vector{Float64},I,V,rows;kwargs...)
end

function pvector_coo!(::Type{T},I,V,rows;kwargs...) where T
    pvector_coo(+,T,I,V,rows;kwargs...)
end

function pvector_coo!(op,::Type{T},I,V,rows;owners=find_owner(rows,I),init=neutral_element(op,eltype(T))) where T
    rows = union_ghost(rows,I,owners)
    t = assemble_coo!(I,V,rows)
    a = PVector{T}(undef,rows)
    @async begin
        I,V = fetch(t)
        insert_coo!(op,a,I,V;init)
    end
end

function insert_coo!(op,values,I,V,indices;init)
    fill!(values,init)
    global_to_local = get_global_to_local(indices)
    for k in 1:length(I)
        gi = I[k]
        li = global_to_local[gi]
        values[li] = V[k]
    end
    values
end

function insert_coo!(op,a::PVector,I,V;init)
    map(a.values,I,V,a.rows.indices) do values,I,V,indices
        insert_coo!(op,values,I,V,indices;init)
    end
    a
end

function assemble_coo!(I,V,rows)
    t = assemble_coo!(I,V,V,rows)
    @async begin
        I,J,V = fetch(t)
        I,V
    end
end

function assemble_coo!(I,J,V,rows)
    part = linear_indices(rows.indices)
    parts_snd = rows.assembler.parts_snd
    parts_rcv = rows.assembler.parts_rcv
    coo_values = map_parts(tuple,I,J,V)
    function setup_snd(part,parts_snd,row_lids,coo_values)
        global_to_local = get_global_to_local(row_lids)
        local_to_owner = get_local_to_owner(row_lids)
        owner_to_i = Dict(( owner=>i for (i,owner) in enumerate(parts_snd) ))
        ptrs = zeros(Int32,length(parts_snd)+1)
        k_gi, k_gj, k_v = coo_values
        for k in 1:length(k_gi)
            gi = k_gi[k]
            li = global_to_local[gi]
            owner = local_to_owner[li]
            if owner != part
                ptrs[owner_to_i[owner]+1] +=1
            end
        end
        length_to_ptrs!(ptrs)
        gi_snd_data = zeros(Int,ptrs[end]-1)
        gj_snd_data = zeros(Int,ptrs[end]-1)
        v_snd_data = zeros(eltype(k_v),ptrs[end]-1)
        for k in 1:length(k_gi)
            gi = k_gi[k]
            li = global_to_local[gi]
            owner = local_to_owner[li]
            if owner != part
                gj = k_gj[k]
                v = k_v[k]
                p = ptrs[owner_to_i[owner]]
                gi_snd_data[p] = gi
                gj_snd_data[p] = gj
                v_snd_data[p] = v
                k_v[k] = zero(v)
                ptrs[owner_to_i[owner]] += 1
            end
        end
        rewind_ptrs!(ptrs)
        gi_snd = JaggedArray(gi_snd_data,ptrs)
        gj_snd = JaggedArray(gj_snd_data,ptrs)
        v_snd = JaggedArray(v_snd_data,ptrs)
        gi_snd, gj_snd, v_snd
    end
    function setup_rcv(part,row_lids,gi_rcv,gj_rcv,v_rcv,coo_values)
        k_gi, k_gj, k_v = coo_values
        ptrs = gi_rcv.ptrs
        current_n = length(k_gi)
        new_n = current_n + length(gi_rcv.data)
        resize!(k_gi,new_n)
        resize!(k_gj,new_n)
        resize!(k_v,new_n)
        for p in 1:length(gi_rcv.data)
            gi = gi_rcv.data[p]
            gj = gj_rcv.data[p]
            v = v_rcv.data[p]
            k_gi[current_n+p] = gi
            k_gj[current_n+p] = gj
            k_v[current_n+p] = v
        end
    end
    aux1 = map(setup_snd,part,parts_snd,rows.indices,coo_values)
    gi_snd, gj_snd, v_snd = aux1 |> unpack
    t1 = exchange(gi_snd,parts_rcv,parts_snd)
    t3 = exchange(v_snd,parts_rcv,parts_snd)
    if J !== V
        t2 = exchange(gj_snd,parts_rcv,parts_snd)
    else
        t2 = t3
    end
    @async begin
        gi_snd = fetch(t1)
        gj_snd = fetch(t2)
        v_snd = fetch(t3) 
        map(setup_rcv,part,rows.indices,gi_rcv,gj_rcv,v_rcv,coo_values)
        I,J,V
    end
end


