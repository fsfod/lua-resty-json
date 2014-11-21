-- Helper wrappring script for loading shared object libac.so (FFI interface)
-- from package.cpath instead of LD_LIBRARTY_PATH.
--

local ffi = require 'ffi'
ffi.cdef[[
typedef enum {
    OT_INT64,
    OT_FP,
    OT_STR,
    OT_BOOL,
    OT_NULL,
    OT_LAST_PRIMITIVE = OT_NULL,
    OT_HASHTAB,
    OT_ARRAY,
    OT_ROOT /* type of dummy object introduced during parsing process */
} obj_ty_t;

struct obj_tag;
typedef struct obj_tag obj_t;
struct obj_tag {
    union {
        char* str_val;
        int64_t int_val;
        double db_val;
        obj_t** elmt_vect; /* element vector for array/hashtab*/
    };
    int32_t obj_ty;
    union {
        int32_t str_len;
        int32_t elmt_num; /* # of element of array/hashtab */
    };
};

struct composite_obj_tag;
typedef struct composite_obj_tag composite_obj_t;

struct composite_obj_tag {
    obj_t obj;
    composite_obj_t* next;
    uint32_t id;
};

struct json_parser;

/* Export functions */
struct json_parser* jp_create(void);
obj_t* jp_parse(struct json_parser*, const char* json, uint32_t len);
const char* jp_get_err(struct json_parser*);
void jp_destroy(struct json_parser*);
]]

local cobj_ptr_t = ffi.typeof("composite_obj_t*")
local obj_ptr_t = ffi.typeof("obj_t*")

local ffi_cast = ffi.cast
local ffi_string = ffi.string

local _M = {}
local tab_new = require 'table.new'

local jp_lib = nil
local jp_create = nil
local jp_parse = nil
local jp_get_err = nil
local jp_destroy = nil

--[[ Find shared object file package.cpath, obviating the need of setting
   LD_LIBRARY_PATH
]]
local function find_shared_obj(cpath, so_name)
    local string_gmatch = string.gmatch
    local string_match = string.match

    for k, v in string_gmatch(cpath, "[^;]+") do
        local so_path = string_match(k, "(.*/)")
        so_path = so_path .. so_name

        -- Don't get me wrong, the only way to know if a file exist is trying
        -- to open it.
        local f = io.open(so_path)
        if f ~= nil then
            io.close(f)
            return so_path
        end
    end
end

function _M.load_json_parser()
    if jp_lib ~= nil then
        return jp_lib
    else
        local so_path = find_shared_obj(package.cpath, "libljson.so")
        if so_path ~= nil then
            jp_lib = ffi.load(so_path)
            jp_create = jp_lib.jp_create
            jp_parse = jp_lib.jp_parse
            jp_get_err = jp_lib.jp_get_err
            jp_destroy = jp_lib.jp_destroy
            return jp_lib
        end
    end
end

function _M.create()
    if not jp_lib then
        _M.load_json_parser()
    end

    if not jp_lib then
        return nil, "fail to load libjson.so"
    end

    local parser_inst = jp_create()
    if parser_inst ~= nil then
        return ffi.gc(parser_inst, jp_destroy)
    end

    return nil, "Fail to create json paprser, likely due to OOM"
end

local ty_int64 = 0
local ty_fp = 1
local ty_str = 2
local ty_bool = 3
local ty_null = 4
local ty_last_primitive = 4
local ty_hashtab = 5
local ty_array= 6

local create_primitive
local create_array
local create_hashtab
local convert_obj

create_primitive = function(obj)
    local ty = obj.obj_ty
    if ty == ty_int64 then
        return tonumber(obj.int_val)
    elseif ty == ty_str then
        return ffi_string(obj.str_val, obj.str_len)
    elseif ty == ty_null then
        return nil
    elseif ty == ty_bool then
        if obj.int_val == 0 then
            return false
        else
            return true
        end
    else
        return tonumber(obj.db_val)
    end

    return nil, "Unknown primitive type"
end

create_array = function(array, cobj_array)
    local elmt_num = array.elmt_num
    local elmt_vect = array.elmt_vect

    local result = {}
    for iter = 1, elmt_num do
        local elmt = elmt_vect[iter - 1]

        local elmt_obj = nil
        if elmt.obj_ty <= ty_last_primitive then
            local err;
            elmt_obj, err = create_primitive(elmt)
            if err then
                return nil
            end
        else
            local cobj = ffi_cast(cobj_ptr_t, elmt);
            elmt_obj = cobj_array[cobj.id + 1]
        end
        result[iter] = elmt_obj
    end

    local array = ffi_cast(cobj_ptr_t, array)
    cobj_array[array.id + 1] = result

    return result;
end

create_hashtab = function(hashtab, cobj_array)
    local elmt_num = hashtab.elmt_num
    local elmt_vect = hashtab.elmt_vect

    local result = {}
    for iter = 1, elmt_num, 2 do
        local key = elmt_vect[iter - 1]
        local val = elmt_vect[iter]

        local key_obj = ffi_string(key.str_val, key.str_len)
        local val_obj = convert_obj(val, cobj_array)
        result[key_obj] = val_obj;
    end

    local ht = ffi_cast(cobj_ptr_t, hashtab)
    cobj_array[ht.id + 1] = result

    return result
end

convert_obj = function(obj, cobj_array)
    local ty = obj.obj_ty
    if ty <= ty_last_primitive then
        return create_primitive(obj)
    elseif ty == ty_array then
        return create_array(obj, cobj_array)
    else
        return create_hashtab(obj, cobj_array)
    end
end

function _M.parse(parser_inst, json)
    local objs = jp_parse(parser_inst, json, #json)
    if objs == nil then
        return nil, ffi.string(jp_get_err(parser_inst))
    end

    local ty = objs.obj_ty
    if ty <= ty_last_primitive then
        return convert_obj(objs)
    end

    local composite_objs = ffi_cast(cobj_ptr_t, objs)
    local cobj_vect = tab_new(composite_objs.id + 1, 0)

    local last_val = nil
    repeat
        last_val = convert_obj(ffi_cast(obj_ptr_t, composite_objs), cobj_vect)
        composite_objs = composite_objs.next
    until composite_objs == nil

    return last_val
end

local print_primitive
local print_table
local print_var

print_primitive = function(luadata)
    if type(luadata) == "string" then
        io.write(string.format("\"%s\"", luadata))
    else
        io.write(tostring(luadata))
    end
end

print_table = function(array)
    io.write("{");
    local elmt_num = 0
    for k, v in pairs(array) do
        if elmt_num > 0 then
            io.write(", ")
        end

        print_primitive(k)
        io.write(":")
        print_var(v)
        elmt_num = elmt_num + 1
    end
    io.write("}");
end

print_var = function(var)
    if type(var) == "table" then
        print_table(var)
    else
        print_primitive(var)
    end
end

function _M.debug(luadata)
    print_var(luadata)
    print("")
end

return _M