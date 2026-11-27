static void reportCallTarget(lua_State* L, StkId func, const Instruction* call)
{
    const Proto* p = L->ci->p;
    const int pc = int(call - p->code);
    for (int i = 0; i < p->sizelocvars; ++i)
    {
        const LocVar& target = p->locvars[i];
        // Compiler reserves register 255 with an empty lifetime for call targets.
        if (target.reg == 255 && target.startpc == pc && target.endpc == pc && target.varname)
            luaG_runerror(L, "attempt to call %s (%s)", getstr(target.varname), luaT_objtypename(L, func));
    }
}
