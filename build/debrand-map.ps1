# Ordered, CASE-SENSITIVE rename table shared by the debranding tools.
#
# PowerShell hashtable keys are case-insensitive, so 'lua_' and 'LUA_' would be
# treated as duplicate keys; this is an ordered array of pairs instead.
#
# Order matters: specific names must precede the generic prefix rules. Every
# replacement target is deliberately non-`lua`-prefixed, so a single sequential
# pass over the table is stable (no rule can re-match another rule's output).
#
# The targets were validated against every top-level declaration in each package
# by build\collision-probe.ps1 -- see that script to re-check after edits.

$DebrandRenames = @(
    # --- structural / one-off names -------------------------------------------
    @('luao_freestanding_newstate', 'lang_freestanding_newstate'),
    @('luao_freestanding_close',    'lang_freestanding_close'),
    @('lua_upvalueindex',           'upvalueindex'),
    @('lua_writestringerror',       'write_string_error'),
    @('lua_writestring',            'write_string'),
    @('lua_writeline',              'write_line'),
    @('lua_stdin_is_tty',           'stdin_is_tty'),
    @('Lua_State',                  'State'),
    @('Lua_Debug',                  'Debug_Info'),
    @('Lua_Writer',                 'Writer'),
    @('Lua_Longjmp',                'Longjmp'),

    # The `luac` bytecode-compiler helpers and the combine driver.
    @('LUAC_COMBINE_FUNCTION', 'COMBINE_FUNCTION'),
    @('luac_combine_reader',   'combine_reader'),
    @('luac_combine',          'combine'),
    @('luac_writer',           'writer'),

    # Bytecode-header constants (reference `LUAC_INT`, `LUAC_DATA`, ...).
    @('LUAC_VERSION', 'HEADER_VERSION'),
    @('LUAC_FORMAT',  'HEADER_FORMAT'),
    @('LUAC_DATA',    'HEADER_DATA'),
    @('LUAC_INT',     'HEADER_INT'),
    @('LUAC_NUM',     'HEADER_NUM'),
    @('LUAC_INST',    'HEADER_INST'),

    @('LUAL_PACKPADBYTE', 'PACKPADBYTE'),

    # `luaU_dump`/`luaU_undump` are the only two names in their subsystem; the
    # generic rule would spell them `dump_dump`/`dump_undump`.
    @('luaU_dump',                  'dump_chunk'),
    @('luaU_undump',                'undump_chunk'),

    # --- specific constants (must precede the generic LUA_/LUAI_ prefix rules) -
    @('LUA_FREESTANDING_WIN64_ABI', 'FREESTANDING_WIN64_ABI'),
    # `MAXSTACK` already exists as a distinct constant (do.odin), so this one
    # cannot simply have its prefix stripped.
    @('LUAI_MAXSTACK',              'MAXSTACK_LIMIT'),
    @('LUA_ENV',                    'ENV_NAME'),
    @('LUAL_BUFFERSIZE',            'AUX_BUFFERSIZE'),
    @('LUAC_PROGNAME',              'COMPILER_PROGNAME'),
    @('LUAC_OUTPUT',                'COMPILER_OUTPUT'),
    @('LUA_PROGNAME',               'PROGNAME'),
    @('LUA_INITVARVERSION',         'INIT_VAR_VERSION'),
    @('LUA_INIT_VAR',               'INIT_VAR'),
    @('LUA_MAXINPUT',               'MAXINPUT'),
    @('LUA_PROMPT2',                'PROMPT2'),
    @('LUA_PROMPT',                 'PROMPT'),

    # --- subsystem procedure prefixes -----------------------------------------
    @('luaopen_', 'open_'),
    @('luaL_',    'aux_'),
    @('luaB_',    'base_'),
    @('luaK_',    'code_'),
    @('luaO_',    'object_'),
    @('luaD_',    'do_'),
    @('luaE_',    'state_'),
    @('luaG_',    'debug_'),
    @('luaH_',    'table_'),
    @('luaS_',    'string_'),
    @('luaT_',    'tm_'),
    @('luaV_',    'vm_'),
    @('luaC_',    'gc_'),
    @('luaF_',    'func_'),
    @('luaX_',    'lex_'),
    @('luaY_',    'parse_'),
    @('luaP_',    'opcode_'),
    @('luaZ_',    'zio_'),
    @('luaM_',    'mem_'),
    @('luai_',    'impl_'),

    # --- remaining constant prefixes (stripped) -------------------------------
    @('LUAI_', ''),
    @('LUA_',  ''),
    @('lua_',  'api_')
)
