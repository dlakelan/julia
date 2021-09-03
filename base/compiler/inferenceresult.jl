# This file is a part of Julia. License is MIT: https://julialang.org/license

function is_argtype_match(@nospecialize(given_argtype),
                          @nospecialize(cache_argtype),
                          overridden_by_const::Bool)
    if isa(given_argtype, Const) || isa(given_argtype, PartialStruct) || isa(given_argtype, PartialOpaque)
        return is_lattice_equal(given_argtype, cache_argtype)
    end
    return !overridden_by_const
end

# In theory, there could be a `cache` containing a matching `InferenceResult`
# for the provided `linfo` and `given_argtypes`. The purpose of this function is
# to return a valid value for `cache_lookup(linfo, argtypes, cache).argtypes`,
# so that we can construct cache-correct `InferenceResult`s in the first place.
function matching_cache_argtypes(linfo::MethodInstance, given_argtypes::Vector, va_override::Bool)
    @assert isa(linfo.def, Method) # ensure the next line works
    nargs::Int = linfo.def.nargs
    given_argtypes = anymap(widenconditional, given_argtypes)
    isva = va_override || linfo.def.isva
    if isva || isvarargtype(given_argtypes[end])
        isva_given_argtypes = Vector{Any}(undef, nargs)
        for i = 1:(nargs - isva)
            isva_given_argtypes[i] = argtype_by_index(given_argtypes, i)
        end
        if isva
            if length(given_argtypes) < nargs && isvarargtype(given_argtypes[end])
                last = lenth(given_argtypes)
            else
                last = nargs
            end
            isva_given_argtypes[nargs] = tuple_tfunc(given_argtypes[last:end])
        end
        given_argtypes = isva_given_argtypes
    end
    @assert length(given_argtypes) == nargs
    cache_argtypes, overridden_by_const = matching_cache_argtypes(linfo, nothing, va_override)
    for i in 1:nargs
        given_argtype = given_argtypes[i]
        cache_argtype = cache_argtypes[i]
        if !is_argtype_match(given_argtype, cache_argtype, overridden_by_const[i])
            # prefer the argtype we were given over the one computed from `linfo`
            cache_argtypes[i] = given_argtype
            overridden_by_const[i] = true
        end
    end
    return cache_argtypes, overridden_by_const
end

function most_general_argtypes(method::Union{Method, Nothing}, @nospecialize(specTypes),
    isva::Bool, withfirst::Bool = true)
    toplevel = method === nothing
    linfo_argtypes = Any[unwrap_unionall(specTypes).parameters...]
    nargs::Int = toplevel ? 0 : method.nargs
    if !withfirst
        # For opaque closure, the closure environment is processed elsewhere
        nargs -= 1
    end
    cache_argtypes = Vector{Any}(undef, nargs)
    # First, if we're dealing with a varargs method, then we set the last element of `args`
    # to the appropriate `Tuple` type or `PartialStruct` instance.
    if !toplevel && isva
        if specTypes == Tuple
            if nargs > 1
                linfo_argtypes = svec(Any[Any for i = 1:(nargs - 1)]..., Tuple.parameters[1])
            end
            vargtype = Tuple
        else
            linfo_argtypes_length = length(linfo_argtypes)
            if nargs > linfo_argtypes_length
                va = linfo_argtypes[linfo_argtypes_length]
                if isvarargtype(va)
                    new_va = rewrap_unionall(unconstrain_vararg_length(va), specTypes)
                    vargtype_elements = Any[new_va]
                    vargtype = Tuple{new_va}
                else
                    vargtype_elements = Any[]
                    vargtype = Tuple{}
                end
            else
                vargtype_elements = Any[]
                for p in linfo_argtypes[nargs:linfo_argtypes_length]
                    p = isvarargtype(p) ? unconstrain_vararg_length(p) : p
                    push!(vargtype_elements, rewrap(p, specTypes))
                end
                for i in 1:length(vargtype_elements)
                    atyp = vargtype_elements[i]
                    if isa(atyp, DataType) && isdefined(atyp, :instance)
                        # replace singleton types with their equivalent Const object
                        vargtype_elements[i] = Const(atyp.instance)
                    elseif isconstType(atyp)
                        vargtype_elements[i] = Const(atyp.parameters[1])
                    end
                end
                vargtype = tuple_tfunc(vargtype_elements)
            end
        end
        cache_argtypes[nargs] = vargtype
        nargs -= 1
    end
    # Now, we propagate type info from `linfo_argtypes` into `cache_argtypes`, improving some
    # type info as we go (where possible). Note that if we're dealing with a varargs method,
    # we already handled the last element of `cache_argtypes` (and decremented `nargs` so that
    # we don't overwrite the result of that work here).
    linfo_argtypes_length = length(linfo_argtypes)
    if linfo_argtypes_length > 0
        n = linfo_argtypes_length > nargs ? nargs : linfo_argtypes_length
        tail_index = n
        local lastatype
        for i = 1:n
            atyp = linfo_argtypes[i]
            if i == n && isvarargtype(atyp)
                atyp = unwrapva(atyp)
                tail_index -= 1
            end
            while isa(atyp, TypeVar)
                atyp = atyp.ub
            end
            if isa(atyp, DataType) && isdefined(atyp, :instance)
                # replace singleton types with their equivalent Const object
                atyp = Const(atyp.instance)
            elseif isconstType(atyp)
                atyp = Const(atyp.parameters[1])
            else
                atyp = rewrap(atyp, specTypes)
            end
            i == n && (lastatype = atyp)
            cache_argtypes[i] = atyp
        end
        for i = (tail_index + 1):nargs
            cache_argtypes[i] = lastatype
        end
    else
        @assert nargs == 0 "invalid specialization of method" # wrong number of arguments
    end
    cache_argtypes
end

function matching_cache_argtypes(linfo::MethodInstance, ::Nothing, va_override::Bool)
    mthd = isa(linfo.def, Method) ? linfo.def::Method : nothing
    cache_argtypes = most_general_argtypes(mthd, linfo.specTypes,
        va_override || (isa(mthd, Method) ? mthd.isva : false))
    return cache_argtypes, falses(length(cache_argtypes))
end

function cache_lookup(linfo::MethodInstance, given_argtypes::Vector{Any}, cache::Vector{InferenceResult})
    method = linfo.def::Method
    nargs::Int = method.nargs
    method.isva && (nargs -= 1)
    length(given_argtypes) >= nargs || return nothing
    for cached_result in cache
        cached_result.linfo === linfo || continue
        cache_match = true
        cache_argtypes = cached_result.argtypes
        cache_overridden_by_const = cached_result.overridden_by_const
        for i in 1:nargs
            if !is_argtype_match(given_argtypes[i],
                                 cache_argtypes[i],
                                 cache_overridden_by_const[i])
                cache_match = false
                break
            end
        end
        if method.isva && cache_match
            cache_match = is_argtype_match(tuple_tfunc(given_argtypes[(nargs + 1):end]),
                                           cache_argtypes[end],
                                           cache_overridden_by_const[end])
        end
        cache_match || continue
        return cached_result
    end
    return nothing
end
