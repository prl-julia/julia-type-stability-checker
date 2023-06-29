#
#
# Module containing macro annotations that allow user to assert type stability
# properties of thir methods
#
#

# @stable!: method definition AST -> IO same definition
# Side effects: Prints warning if finds unstable signature instantiation.
#               Relies on is_stable_method.
macro stable!(def)
    (fname, argtypes) = split_def(def)
    quote
	    $(esc(def))
        m = which($(esc(fname)), $argtypes)
        mst = is_stable_method(m)

        print_uns(m, mst)
        (f,_) = split_method(m)
        f
    end
end

# Interface for delayed stability checks; useful for define-after-use cases (cf. Issue #3)
# @stable delays the check until `check_all_stable` is called. The list of checks to perform
# is stored in a global list that needs cleenup once in a while with `clean_checklist`.
checklist=[]
macro stable(def)
    push!(checklist, def)
    def
end
check_all_stable() = begin
    @debug "start check_all_stable"
    for def in checklist
        (fname, argtypes) = split_def(def)
        @debug "Process method $fname with signature: $argtypes"
        m = which(eval(fname), eval(argtypes))
        mst = is_stable_method(m)

        print_uns(m, mst)
    end
end
clean_checklist() = begin
    global checklist = [];
end

# Variant of @stable! that doesn't splice the provided function definition
# into the global namespace. Mostly for testing purposes. Relies on Julia's
# hygiene support.
macro stable!_nop(def)
    (fname, argtypes) = split_def(def)
    quote
	    $(def)
        m = which($(fname), $argtypes)
        mst = is_stable_method(m)

        print_uns(m, mst)
    end
end
