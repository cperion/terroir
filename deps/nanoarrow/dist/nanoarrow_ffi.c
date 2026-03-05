// Thin wrapper exposing nanoarrow's inline functions for LuaJIT FFI
#include "nanoarrow.h"

int na_array_init(struct ArrowArray* array, int type) {
    return ArrowArrayInitFromType(array, (enum ArrowType)type);
}

int na_array_start(struct ArrowArray* array) {
    return ArrowArrayStartAppending(array);
}

int na_array_append_int(struct ArrowArray* array, int64_t value) {
    return ArrowArrayAppendInt(array, value);
}

int na_array_append_uint(struct ArrowArray* array, uint64_t value) {
    return ArrowArrayAppendUInt(array, value);
}

int na_array_append_double(struct ArrowArray* array, double value) {
    return ArrowArrayAppendDouble(array, value);
}

int na_array_append_string(struct ArrowArray* array, const char* value) {
    struct ArrowStringView sv;
    sv.data = value;
    sv.size_bytes = (int64_t)strlen(value);
    return ArrowArrayAppendString(array, sv);
}

int na_array_append_bytes(struct ArrowArray* array, const uint8_t* data, int64_t len) {
    struct ArrowBufferView bv;
    bv.data.as_uint8 = data;
    bv.size_bytes = len;
    return ArrowArrayAppendBytes(array, bv);
}

int na_array_append_null(struct ArrowArray* array) {
    return ArrowArrayAppendNull(array, 1);
}

int na_array_finish(struct ArrowArray* array) {
    return ArrowArrayFinishBuildingDefault(array, NULL);
}

void na_array_release(struct ArrowArray* array) {
    if (array->release) {
        array->release(array);
    }
}

int na_schema_init(struct ArrowSchema* schema, int type) {
    return ArrowSchemaInitFromType(schema, (enum ArrowType)type);
}

int na_schema_set_fixed_size(struct ArrowSchema* schema, int type, int32_t byte_width) {
    return ArrowSchemaSetTypeFixedSize(schema, (enum ArrowType)type, byte_width);
}

void na_schema_release(struct ArrowSchema* schema) {
    if (schema->release) {
        schema->release(schema);
    }
}

int na_array_allocate_children(struct ArrowArray* array, int64_t n_children) {
    return ArrowArrayAllocateChildren(array, n_children);
}

int na_array_finish_element(struct ArrowArray* array) {
    return ArrowArrayFinishElement(array);
}

// ArrowArrayView reader wrappers (inline functions need C wrappers for FFI)

int na_view_init_from_schema(struct ArrowArrayView* view,
                             const struct ArrowSchema* schema) {
    return ArrowArrayViewInitFromSchema(view, schema, NULL);
}

int na_view_set_array(struct ArrowArrayView* view,
                      const struct ArrowArray* array) {
    return ArrowArrayViewSetArray(view, array, NULL);
}

int na_view_set_array_minimal(struct ArrowArrayView* view,
                              const struct ArrowArray* array) {
    return ArrowArrayViewSetArrayMinimal(view, array, NULL);
}

void na_view_reset(struct ArrowArrayView* view) {
    ArrowArrayViewReset(view);
}

double na_view_get_double(const struct ArrowArrayView* view, int64_t i) {
    return ArrowArrayViewGetDoubleUnsafe(view, i);
}

int64_t na_view_get_int(const struct ArrowArrayView* view, int64_t i) {
    return ArrowArrayViewGetIntUnsafe(view, i);
}

int8_t na_view_is_null(const struct ArrowArrayView* view, int64_t i) {
    return ArrowArrayViewIsNull(view, i);
}

int64_t na_view_sizeof(void) {
    return (int64_t)sizeof(struct ArrowArrayView);
}

int64_t na_view_list_child_offset(const struct ArrowArrayView* view, int64_t i) {
    return ArrowArrayViewListChildOffset(view, i);
}

struct ArrowArrayView* na_view_child(const struct ArrowArrayView* view, int64_t i) {
    return view->children[i];
}

int64_t na_view_length(const struct ArrowArrayView* view) {
    return view->length;
}

// GeoArrow benchmark helpers:
// list_view layout must be List<Struct<x: float64, y: float64>>

struct na_bbox {
    double min_x;
    double min_y;
    double max_x;
    double max_y;
};

struct na_point {
    double x;
    double y;
};

struct na_bbox na_geo_bbox(const struct ArrowArrayView* list_view) {
    struct na_bbox out = {1e30, 1e30, -1e30, -1e30};
    const struct ArrowArrayView* struct_view = list_view->children[0];
    const struct ArrowArrayView* x_view = struct_view->children[0];
    const struct ArrowArrayView* y_view = struct_view->children[1];
    int64_t nrows = list_view->length;

    for (int64_t row = 0; row < nrows; row++) {
        int64_t start = ArrowArrayViewListChildOffset(list_view, row);
        int64_t stop = ArrowArrayViewListChildOffset(list_view, row + 1);
        for (int64_t idx = start; idx < stop; idx++) {
            double x = ArrowArrayViewGetDoubleUnsafe(x_view, idx);
            double y = ArrowArrayViewGetDoubleUnsafe(y_view, idx);
            if (x < out.min_x) out.min_x = x;
            if (x > out.max_x) out.max_x = x;
            if (y < out.min_y) out.min_y = y;
            if (y > out.max_y) out.max_y = y;
        }
    }

    return out;
}

void na_geo_area(const struct ArrowArrayView* list_view, double* areas) {
    const struct ArrowArrayView* struct_view = list_view->children[0];
    const struct ArrowArrayView* x_view = struct_view->children[0];
    const struct ArrowArrayView* y_view = struct_view->children[1];
    int64_t nrows = list_view->length;

    for (int64_t row = 0; row < nrows; row++) {
        int64_t start = ArrowArrayViewListChildOffset(list_view, row);
        int64_t stop = ArrowArrayViewListChildOffset(list_view, row + 1);
        double sum = 0.0;
        for (int64_t idx = start; idx + 1 < stop; idx++) {
            double x0 = ArrowArrayViewGetDoubleUnsafe(x_view, idx);
            double y0 = ArrowArrayViewGetDoubleUnsafe(y_view, idx);
            double x1 = ArrowArrayViewGetDoubleUnsafe(x_view, idx + 1);
            double y1 = ArrowArrayViewGetDoubleUnsafe(y_view, idx + 1);
            sum += x0 * y1 - x1 * y0;
        }
        areas[row] = sum * 0.5;
    }
}

void na_geo_centroid(const struct ArrowArrayView* list_view, struct na_point* centroids) {
    const struct ArrowArrayView* struct_view = list_view->children[0];
    const struct ArrowArrayView* x_view = struct_view->children[0];
    const struct ArrowArrayView* y_view = struct_view->children[1];
    int64_t nrows = list_view->length;

    for (int64_t row = 0; row < nrows; row++) {
        int64_t start = ArrowArrayViewListChildOffset(list_view, row);
        int64_t stop = ArrowArrayViewListChildOffset(list_view, row + 1);
        int64_t n = stop - start - 1;  // Exclude duplicated closing vertex
        double sx = 0.0;
        double sy = 0.0;

        for (int64_t idx = start; idx < start + n; idx++) {
            sx += ArrowArrayViewGetDoubleUnsafe(x_view, idx);
            sy += ArrowArrayViewGetDoubleUnsafe(y_view, idx);
        }

        if (n > 0) {
            centroids[row].x = sx / (double)n;
            centroids[row].y = sy / (double)n;
        } else {
            centroids[row].x = 0.0;
            centroids[row].y = 0.0;
        }
    }
}
