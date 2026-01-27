#include "CSearch.h"
#include <string.h>
#include <stdlib.h>

int32_t perform_search_scan(
    const uint8_t* data_ptr,
    size_t item_base_offset,
    size_t item_record_size,
    size_t start_index,
    size_t end_index,
    const uint8_t* query_ptr,
    size_t query_len,
    int32_t* results_buffer
) {
    int32_t match_count = 0;
    const uint8_t* items_start = data_ptr + item_base_offset;

    for (size_t i = start_index; i < end_index; i++) {
        size_t offset = i * item_record_size;
        const uint8_t* item_ptr = items_start + offset;

        // Read lowerName location (Offset 36, Len 40)
        uint32_t lower_name_offset = *(const uint32_t*)(item_ptr + 36);
        uint32_t lower_name_len = *(const uint32_t*)(item_ptr + 40);

        const uint8_t* name_ptr = data_ptr + lower_name_offset;

        if (memmem(name_ptr, lower_name_len, query_ptr, query_len) != NULL) {
            results_buffer[match_count++] = (int32_t)i;
        }
    }

    return match_count;
}

// Sorting Implementation

typedef struct {
    const uint8_t* data_ptr;
    size_t item_base_offset;
    size_t item_record_size;
    bool ascending;
} SortContext;

static inline const uint8_t* get_item_ptr(const SortContext* ctx, int32_t index) {
    return ctx->data_ptr + ctx->item_base_offset + ((size_t)index * ctx->item_record_size);
}

static int compare_indices_name(void* thunk, const void* a, const void* b) {
    SortContext* ctx = (SortContext*)thunk;
    int32_t idxA = *(const int32_t*)a;
    int32_t idxB = *(const int32_t*)b;

    const uint8_t* ptrA = get_item_ptr(ctx, idxA);
    const uint8_t* ptrB = get_item_ptr(ctx, idxB);

    uint32_t offA = *(const uint32_t*)(ptrA + 20);
    uint32_t lenA = *(const uint32_t*)(ptrA + 24);

    uint32_t offB = *(const uint32_t*)(ptrB + 20);
    uint32_t lenB = *(const uint32_t*)(ptrB + 24);

    const char* strA = (const char*)(ctx->data_ptr + offA);
    const char* strB = (const char*)(ctx->data_ptr + offB);

    uint32_t minLen = (lenA < lenB) ? lenA : lenB;
    int cmp = memcmp(strA, strB, minLen);

    if (cmp == 0) {
        if (lenA < lenB) cmp = -1;
        else if (lenA > lenB) cmp = 1;
    }

    return ctx->ascending ? cmp : -cmp;
}

static int compare_indices_path(void* thunk, const void* a, const void* b) {
    SortContext* ctx = (SortContext*)thunk;
    int32_t idxA = *(const int32_t*)a;
    int32_t idxB = *(const int32_t*)b;

    const uint8_t* ptrA = get_item_ptr(ctx, idxA);
    const uint8_t* ptrB = get_item_ptr(ctx, idxB);

    uint32_t offA = *(const uint32_t*)(ptrA + 28);
    uint32_t lenA = *(const uint32_t*)(ptrA + 32);

    uint32_t offB = *(const uint32_t*)(ptrB + 28);
    uint32_t lenB = *(const uint32_t*)(ptrB + 32);

    const char* strA = (const char*)(ctx->data_ptr + offA);
    const char* strB = (const char*)(ctx->data_ptr + offB);

    uint32_t minLen = (lenA < lenB) ? lenA : lenB;
    int cmp = memcmp(strA, strB, minLen);

    if (cmp == 0) {
        if (lenA < lenB) cmp = -1;
        else if (lenA > lenB) cmp = 1;
    }

    return ctx->ascending ? cmp : -cmp;
}

static int compare_indices_size(void* thunk, const void* a, const void* b) {
    SortContext* ctx = (SortContext*)thunk;
    int32_t idxA = *(const int32_t*)a;
    int32_t idxB = *(const int32_t*)b;

    const uint8_t* ptrA = get_item_ptr(ctx, idxA);
    const uint8_t* ptrB = get_item_ptr(ctx, idxB);

    int64_t valA = *(const int64_t*)(ptrA + 0);
    int64_t valB = *(const int64_t*)(ptrB + 0);

    if (valA < valB) return ctx->ascending ? -1 : 1;
    if (valA > valB) return ctx->ascending ? 1 : -1;
    return 0;
}

static int compare_indices_date(void* thunk, const void* a, const void* b) {
    SortContext* ctx = (SortContext*)thunk;
    int32_t idxA = *(const int32_t*)a;
    int32_t idxB = *(const int32_t*)b;

    const uint8_t* ptrA = get_item_ptr(ctx, idxA);
    const uint8_t* ptrB = get_item_ptr(ctx, idxB);

    double valA = *(const double*)(ptrA + 8);
    double valB = *(const double*)(ptrB + 8);

    if (valA < valB) return ctx->ascending ? -1 : 1;
    if (valA > valB) return ctx->ascending ? 1 : -1;
    return 0;
}

void perform_index_sort(
    int32_t* indices,
    size_t count,
    const uint8_t* data_ptr,
    size_t item_base_offset,
    size_t item_record_size,
    SearchSortKey key,
    bool ascending
) {
    SortContext ctx;
    ctx.data_ptr = data_ptr;
    ctx.item_base_offset = item_base_offset;
    ctx.item_record_size = item_record_size;
    ctx.ascending = ascending;

    int (*compar)(void *, const void *, const void *) = NULL;

    switch (key) {
        case SORT_KEY_NAME: compar = compare_indices_name; break;
        case SORT_KEY_PATH: compar = compare_indices_path; break;
        case SORT_KEY_SIZE: compar = compare_indices_size; break;
        case SORT_KEY_DATE: compar = compare_indices_date; break;
    }

    if (compar != NULL) {
        // macOS qsort_r
        qsort_r(indices, count, sizeof(int32_t), &ctx, compar);
    }
}

int32_t perform_path_lookup(
    const uint8_t* data_ptr,
    size_t item_base_offset,
    size_t item_record_size,
    size_t count,
    const char* target_path,
    size_t target_len
) {
    const uint8_t* items_start = data_ptr + item_base_offset;

    // Linear scan for now.
    // Since index.bin is sorted by NAME, we can't binary search by PATH.
    // However, C linear scan is very fast.

    for (size_t i = 0; i < count; i++) {
        size_t offset = i * item_record_size;
        const uint8_t* item_ptr = items_start + offset;

        // Read path location (Offset 28, Len 32)
        uint32_t path_offset = *(const uint32_t*)(item_ptr + 28);
        uint32_t path_len = *(const uint32_t*)(item_ptr + 32);

        if (path_len != target_len) continue;

        const char* path_ptr = (const char*)(data_ptr + path_offset);

        if (memcmp(path_ptr, target_path, target_len) == 0) {
            return (int32_t)i;
        }
    }

    return -1;
}
