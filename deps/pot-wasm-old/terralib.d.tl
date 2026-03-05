local record terralib
    version: string
    llvm_version: number
    isverbose: number
    isdebug: number
    terrahome: string
    
    cudahome: string
    cudalibpaths: {string: string}
    
    includepath: string
    systemincludes: List<string>
    
    record types
        int8: Type
        int16: Type
        int32: Type
        int64: Type
        uint8: Type
        uint16: Type
        uint32: Type
        uint64: Type
        float: Type
        double: Type
        bool: Type
        int: Type
        uint: Type
        long: Type
        intptr: Type
        ptrdiff: Type
        rawstring: Type
        niltype: Type
        opaque: Type
        error: Type
        unit: Type
        
        pointer: function(t: Type, addressspace: number): Type
        array: function(t: Type, n: number): Type
        vector: function(t: Type, n: number): Type
        functype: function(params: {Type}, ret: Type, isvararg: boolean): Type
        tuple: function(...: Type): Type
        funcpointer: function(params: {Type} | Type, ret: Type | {Type}, isvararg: boolean): Type
        
        newstruct: function(displayname: string, depth: number): Type
        newstructwithanchor: function(displayname: string, anchor: Anchor): Type
        
        istype: function(t: any): boolean
        
        ctypetoterra: {number: Type}
    end
    
    record Type
        kind: string
        name: string
        
        isprimitive: function(self: Type): boolean
        isintegral: function(self: Type): boolean
        isfloat: function(self: Type): boolean
        isarithmetic: function(self: Type): boolean
        islogical: function(self: Type): boolean
        canbeord: function(self: Type): boolean
        ispointer: function(self: Type): boolean
        isarray: function(self: Type): boolean
        isfunction: function(self: Type): boolean
        isstruct: function(self: Type): boolean
        ispointertostruct: function(self: Type): boolean
        ispointertofunction: function(self: Type): boolean
        isaggregate: function(self: Type): boolean
        iscomplete: function(self: Type): boolean
        isvector: function(self: Type): boolean
        isunit: function(self: Type): boolean
        isprimitiveorvector: function(self: Type): boolean
        isintegralorvector: function(self: Type): boolean
        isarithmeticorvector: function(self: Type): boolean
        islogicalorvector: function(self: Type): boolean
        canbeordorvector: function(self: Type): boolean
        
        complete: function(self: Type): Type
        cstring: function(self: Type): string
        layoutstring: function(self: Type): string
        printpretty: function(self: Type)
        printraw: function(self: Type)
        
        getentries: function(self: Type): List<{field: string | Label, type: Type}>
        getlayout: function(self: Type): {entries: List<{type: Type, key: string | Label, allocation: number, inunion: boolean}>, keytoindex: {string | Label: number}}
        getmethod: function(self: Type, methodname: string): TerraFunction | Macro, string
        getfield: function(self: Type, fieldname: string): {type: Type, key: string, allocation: number, inunion: boolean}, string
        getfields: function(self: Type): List<{type: Type, key: string, allocation: number, inunion: boolean}>
        setconvertible: function(self: Type, b: string)
        
        type: Type
        N: number
        addressspace: number
        
        parameters: List<Type>
        returntype: Type
        isvararg: boolean
        
        entries: List<any>
        methods: {string: TerraFunction | Macro}
        metamethods: {string: any}
        anchor: Anchor
        incomplete: boolean
        undefined: boolean
        convertible: string
    end
    
    record TerraFunction
        name: string
        type: Type
        definition: Definition
        anchor: Anchor
        stats: {string: number}
        rawjitptr: userdata
        ffiwrapper: userdata
        
        gettype: function(self: TerraFunction): Type
        getname: function(self: TerraFunction): string
        setname: function(self: TerraFunction, name: string): TerraFunction
        getpointer: function(self: TerraFunction): function
        compile: function(self: TerraFunction): userdata
        disas: function(self: TerraFunction)
        printstats: function(self: TerraFunction)
        isdefined: function(self: TerraFunction): boolean
        isextern: function(self: TerraFunction): boolean
        setinlined: function(self: TerraFunction, v: boolean)
        setoptimized: function(self: TerraFunction, v: boolean)
        setcallingconv: function(self: TerraFunction, v: string)
        setnoreturn: function(self: TerraFunction, v: boolean)
        adddefinition: function(self: TerraFunction, fn: Definition | TerraFunction)
        resetdefinition: function(self: TerraFunction, fn: Definition | TerraFunction)
        prettystring: function(self: TerraFunction, breaklines: boolean): string
        printpretty: function(self: TerraFunction, bl: boolean)
        
        __call: function(self: TerraFunction, ...: any): any
        __tostring: function(self: TerraFunction): string
    end
    
    record GlobalVariable
        name: string
        type: Type
        initializer: Tree
        addressspace: number
        extern: boolean
        constant: boolean
        symbol: Symbol
        anchor: Anchor
        rawjitptr: userdata
        ffiwrapper: userdata
        
        gettype: function(self: GlobalVariable): Type
        getname: function(self: GlobalVariable): string
        setname: function(self: GlobalVariable, name: string): GlobalVariable
        getpointer: function(self: GlobalVariable): userdata
        isextern: function(self: GlobalVariable): boolean
        isconstant: function(self: GlobalVariable): boolean
        setinitializer: function(self: GlobalVariable, init: any)
        get: function(self: GlobalVariable): any
        set: function(self: GlobalVariable, v: any)
    end
    
    record OverloadedTerraFunction
        name: string
        definitions: List<TerraFunction>
        
        adddefinition: function(self: OverloadedTerraFunction, fn: TerraFunction): OverloadedTerraFunction
        getdefinitions: function(self: OverloadedTerraFunction): List<TerraFunction>
    end
    
    record Symbol
        type: Type
        displayname: string
        id: number
        
        __tostring: function(self: Symbol): string
        tocname: function(self: Symbol): string
    end
    
    record Label
        displayname: string
        id: number
        
        __tostring: function(self: Label): string
        tocname: function(self: Label): string
    end
    
    record Anchor
        linenumber: number
        filename: string
        offset: number
    end
    
    record Quote
        tree: Tree
        
        astype: function(self: Quote): Type
        isluaobject: function(self: Quote): boolean
        gettype: function(self: Quote): Type
        islvalue: function(self: Quote): boolean
        asvalue: function(self: Quote): any
        prettystring: function(self: Quote, breaklines: boolean): string
        printpretty: function(self: Quote, bl: boolean)
        __tostring: function(self: Quote): string
    end
    
    record Macro
        fromterra: function
        fromlua: function
        _internal: boolean
        
        run: function(self: Macro, ctx: any, tree: Tree, ...: Quote): any
    end
    
    record Tree
        kind: string
        type: Type
        lvalue: boolean
        linenumber: number
        filename: string
        offset: number
        
        is: function(self: Tree, value: string): boolean
        copy: function(self: Tree, newfields: {string: any}): Tree
        aserror: function(self: Tree): Tree
        setlvalue: function(self: Tree, v: boolean): Tree
        withtype: function(self: Tree, typ: Type): Tree
        printraw: function(self: Tree)
    end
    
    record Target
        Triple: string
        CPU: string
        Features: string
        llvm_target: userdata
        cnametostruct: {general: {string: Type}, tagged: {string: Type}}
        
        getorcreatecstruct: function(self: Target, displayname: string, tagged: boolean): Type
    end
    
    record CompilationUnit
        llvm_cu: userdata
        symbols: {any: any}
        
        addvalue: function(self: CompilationUnit, k: string | TerraFunction | GlobalVariable, v: TerraFunction | GlobalVariable): userdata
        jitvalue: function(self: CompilationUnit, v: TerraFunction | GlobalVariable): userdata
        free: function(self: CompilationUnit)
        dump: function(self: CompilationUnit)
        saveobj: function(self: CompilationUnit, filename: string, filekind: string, arguments: {string: any}, optimize: boolean): string
    end
    
    record Definition
        kind: string
        name: string
        type: Type
        parameters: List<AllocVar>
        is_varargs: boolean
        body: Tree
        labeldepths: {Label: number}
        globalsused: List<GlobalValue>
        alwaysinline: boolean
        dontoptimize: boolean
        callingconv: string
        noreturn: boolean
    end
    
    record AllocVar
        kind: string
        name: string
        symbol: Symbol
        type: Type
        lvalue: boolean
        settype: function(self: AllocVar, typ: Type)
    end
    
    record List<T>
        insert: function(self: List<T>, v: T)
        insertall: function(self: List<T>, other: List<T> | {T})
        remove: function(self: List<T>): T
        map: function(self: List<T>, fn: function(v: T): any): List<any>
        concat: function(self: List<T>, sep: string): string
        size: function(self: List<T>): number
    end
    
    record Environment
        enterblock: function(self: Environment)
        leaveblock: function(self: Environment)
        localenv: function(self: Environment): {string: any}
        luaenv: function(self: Environment): {string: any}
        combinedenv: function(self: Environment): {string: any}
    end
    
    record Diagnostics
        errors: List<string>
        
        reporterror: function(self: Diagnostics, anchor: Anchor, ...: any)
        haserrors: function(self: Diagnostics): boolean
        finishandabortiferrors: function(self: Diagnostics, msg: string, depth: number)
    end
    
    record GlobalValue
        name: string
        type: Type
        anchor: Anchor
        
        gettype: function(self: GlobalValue): Type
        getname: function(self: GlobalValue): string
        setname: function(self: GlobalValue, name: string): GlobalValue
        compile: function(self: GlobalValue): userdata
        getpointer: function(self: GlobalValue): userdata
    end
    
    record LanguageExtension
        record TokenType
            name: string
        end
        
        name: TokenType
        string: TokenType
        number: TokenType
        eof: TokenType
        default: TokenType
        tokenkindtotoken: {string: TokenType}
        
        tokentype: TokenType
    end
    
    languageextension: LanguageExtension
    
    kinds: {string: number}
    
    irtypes: any
    
    load: function(reader: function(): string, chunkname: string): function
    loadfile: function(filename: string): function
    loadstring: function(s: string): function
    
    new: function(terratype: Type, ...: any): userdata
    cast: function(terratype: Type, obj: any): userdata
    constant: function(typ: Type, init: any): Quote
    typeof: function(obj: userdata): Type
    type: function(t: any): string
    
    externfunction: function(name: string, typ: Type, anchor: Anchor): TerraFunction
    overloadedfunction: function(name: string, init: {TerraFunction}): OverloadedTerraFunction
    
    global: function(typ: Type, init: any, name: string, isextern: boolean, isconstant: boolean, addressspace: number): GlobalVariable
    
    newsymbol: function(typ: Type, displayname: string): Symbol
    newlabel: function(displayname: string): Label
    
    newquote: function(tree: Tree): Quote
    definequote: function(tree: Tree, envfn: function): Quote
    
    createmacro: function(fromterra: function, fromlua: function): Macro
    internalmacro: function(fromterra: function, fromlua: function): Macro
    
    newtarget: function(tbl: {Triple: string, CPU: string, Features: string, FloatABIHard: boolean}): Target
    istarget: function(a: any): boolean
    nativetarget: Target
    getcudatarget: function(): Target
    
    newcompilationunit: function(target: Target, opt: boolean, profile: {fastmath: boolean | string | {string}}): CompilationUnit
    jitcompilationunit: CompilationUnit
    
    saveobj: function(filename: string, filekind: string, env: {string: TerraFunction | GlobalVariable}, arguments: {string: any}, target: Target, optimize: boolean | {fastmath: boolean}): string
    saveobjimpl: function(filename: string, filekind: string, cu: CompilationUnit, arguments: {string: any}, optimize: boolean): string
    
    linklibrary: function(filename: string)
    linkllvm: function(filename: string, target: Target, fromstring: boolean): {extern: function(self: any, name: string, typ: Type): TerraFunction}
    linkllvmstring: function(str: string, target: Target): {extern: function(self: any, name: string, typ: Type): TerraFunction}
    linklibraryimpl: function(filename: string)
    linkllvmimpl: function(target: userdata, filename: string, fromstring: boolean)
    
    includec: function(fname: string, cargs: {string}, target: Target): {string: any}, {string: any}, {string: number}
    includecstring: function(code: string, cargs: {string}, target: Target): {string: any}, {string: any}, {string: number}
    
    registercfile: function(target: Target, code: string, args: {string}, headerprovider: function(path: string): {kind: string, contents: string, size: number}): {general: {string: any}, tagged: {string: any}, errors: {string: string}, macros: {string: number}}
    
    sizeof: Macro
    offsetof: function(terratype: Type, field: string | Label): number
    llvmsizeof: function(cu: CompilationUnit, terratype: Type): number
    
    printraw: function(self: any)
    newanchor: function(depth: number): Anchor
    disassemble: function(gv: userdata, ptr: userdata)
    
    newlist: function(...: any): List<any>
    islist: function(l: any): boolean
    israwlist: function(l: any): boolean
    
    istree: function(v: any): boolean
    
    isfunction: function(obj: any): boolean
    isglobalvar: function(obj: any): boolean
    isoverloadedfunction: function(obj: any): boolean
    ismacro: function(t: any): boolean
    isquote: function(t: any): boolean
    issymbol: function(s: any): boolean
    islabel: function(l: any): boolean
    isconstant: function(obj: any): boolean
    
    newenvironment: function(_luaenv: {string: any}): Environment
    environment: Environment
    
    newdiagnostics: function(): Diagnostics
    diagnostics: Diagnostics
    
    cudacompile: function(...: any): any
    toptximpl: function(cu: CompilationUnit, annotations: {{string, string, number}}, dumpmodule: boolean, version: number, libdevice: string): string
    
    registerinternalizedfiles: function(names: userdata, contents: userdata, sizes: userdata)
    
    inittarget: function(triple: string, cpu: string, features: string, floatabihard: boolean): userdata
    freetarget: function(target: userdata)
    initcompilationunit: function(target: userdata, opt: boolean, profile: {fastmath: {string}}): userdata
    compilationunitaddvalue: function(cu: CompilationUnit, k: string | any, v: any): userdata
    freecompilationunit: function(cu: userdata)
    jit: function(llvm_cu: userdata, gv: userdata): userdata
    disassemble: function(idx: number, fn: userdata)
    pointertolightuserdata: function(ptr: userdata): userdata
    bindtoluaapi: function(fn: function)
    gcdebug: function()
    saveobjimpl: function(filename: string, filekind: string, cu: CompilationUnit, arguments: {string: any}, optimize: boolean): string
    currenttimeinseconds: function(): number
    isintegral: function(t: any): boolean
    dumpmodule: function(llvm_cu: userdata)
    
    pointertolightuserdata: function(ptr: any): lightuserdata
    
    memoize: function(fn: function): function
    
    importlanguage: function(languages: {any}, entrypoints: {string: any}, langstring: string)
    unimportlanguages: function(languages: {any}, N: number, entrypoints: {string: any})
    runlanguage: function(lang: any, cur: function, lookahead: function, next: function, embeddedcode: function, source: string, isstatement: boolean, islocal: boolean): function, {{string}}, {string}
    
    defineobjects: function(fmt: string, envfn: function, ...: any): TerraFunction ...
    anonstruct: function(tree: Tree, envfn: function): Type
    anonfunction: function(tree: Tree, envfn: function): TerraFunction
    
    intrinsic: function(str: string | function, typ: Type | function): Macro
    
    asm: Macro
    
    attrload: Macro
    attrstore: Macro
    fence: Macro
    cmpxchg: Macro
    atomicrmw: Macro
    
    debuginfo: Macro
    
    select: Macro
    
    unpackstruct: Macro
    unpacktuple: Macro
    
    traceback: function
    backtrace: function
    lookupsymbol: function
    lookupline: function
    disas: function
    initdebugfns: function(traceback: userdata, backtrace: userdata, lookupsymbol: userdata, lookupline: userdata, disas: userdata)
    
    record SymbolInfo
        addr: opaque
        size: uint64
        name: rawstring
        namelength: uint64
    end
    
    record LineInfo
        name: rawstring
        namelength: uint64
        linenum: uint64
    end
    
    SymbolInfo: Type
    LineInfo: Type
    CUDAParams: Type
    
    queryregvalue: function(key: string, value: string): string
    findvisualstudiotoolchain: function(): string
    listsubdirectories: function(path: string): {string}
    vshome: string
    vclinker: string
    sdklib: string
    getvclinker: function(target: string): string, string, string
    
    makeenv: function(env: {string: any}, defined: {string: boolean}, g: {string: any}): {string: any}
    
    fulltrace: boolean
    slimtrace: boolean
    
    record asdl
        NewContext: function(): any
        List: function(...: any): List<any>
    end
end

global macro: terralib.Macro
global symbol: function(typ: terralib.Type, displayname: string): terralib.Symbol
global label: function(displayname: string): terralib.Label
global sizeof: terralib.Macro
global vector: terralib.Macro
global vectorof: terralib.Macro
global array: terralib.Macro
global arrayof: terralib.Macro
global unpackstruct: terralib.Macro
global unpacktuple: terralib.Macro
global tuple: function(...: terralib.Type): terralib.Type
global global: function(typ: terralib.Type, init: any, name: string, isextern: boolean, isconstant: boolean, addressspace: number): terralib.GlobalVariable
global constant: function(typ: terralib.Type, init: any): terralib.Quote
global operator: terralib.Macro
global terralib: terralib

global int8: terralib.Type
global int16: terralib.Type
global int32: terralib.Type
global int64: terralib.Type
global uint8: terralib.Type
global uint16: terralib.Type
global uint32: terralib.Type
global uint64: terralib.Type
global float: terralib.Type
global double: terralib.Type
global bool: terralib.Type
global int: terralib.Type
global uint: terralib.Type
global long: terralib.Type
global intptr: terralib.Type
global ptrdiff: terralib.Type
global rawstring: terralib.Type
global niltype: terralib.Type
global opaque: terralib.Type

return terralib
