    bool hasCallTargets = false;

    void recordCallTarget(AstExpr* target, uint32_t pc)
    {
        // Build a bounded dotted name from right to left. Only name expressions can
        // be described without guessing which value a computed expression returned.
        char name[96];
        size_t start = sizeof(name);
        for (;;)
        {
            if (AstExprGroup* group = target->as<AstExprGroup>())
            {
                target = group->expr;
                continue;
            }
            if (AstExprTypeAssertion* assertion = target->as<AstExprTypeAssertion>())
            {
                target = assertion->expr;
                continue;
            }
            if (AstExprInstantiate* instantiation = target->as<AstExprInstantiate>())
            {
                target = instantiation->expr;
                continue;
            }

            AstExprIndexName* field = target->as<AstExprIndexName>();
            AstExprLocal* local = target->as<AstExprLocal>();
            AstExprGlobal* global = target->as<AstExprGlobal>();
            if (!field && !local && !global)
                return;

            const char* part = field ? field->index.value : local ? local->local->name.value : global->name.value;
            size_t length = strlen(part);
            if (length + (field ? 1 : 0) > start)
                return;
            start -= length;
            memcpy(name + start, part, length);
            if (!field)
                break;
            name[--start] = '.';
            target = field->expr;
        }

        // An empty lifetime at an out-of-range register is invisible to local
        // inspection and remapped with the instruction by BytecodeBuilder.
        bytecode.pushDebugLocal(sref(names.getOrAdd(name + start, sizeof(name) - start)), uint8_t(kMaxRegisterCount), pc, pc);
        hasCallTargets = true;
    }
