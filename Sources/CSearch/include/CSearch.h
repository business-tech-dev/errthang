#ifndef CSearch_h
#define CSearch_h

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Performs a scan over the binary index for items matching the query.
// Returns the number of matches found and written to results_buffer.
// results_buffer must be large enough to hold (end_index - start_index) items.
int32_t perform_search_scan(
    const uint8_t* data_ptr,
    size_t item_base_offset,
    size_t item_record_size,
    size_t start_index,
    size_t end_index,
    const uint8_t* query_ptr,
    size_t query_len,
    int32_t* results_buffer
);

typedef enum {
    SORT_KEY_NAME = 0,
    SORT_KEY_PATH = 1,
    SORT_KEY_SIZE = 2,
    SORT_KEY_DATE = 3
} SearchSortKey;

// Sorts the indices in-place based on the binary data and sort key.
void perform_index_sort(
    int32_t* indices,
    size_t count,
    const uint8_t* data_ptr,
    size_t item_base_offset,
    size_t item_record_size,
    SearchSortKey key,
    bool ascending
);

// Search for an exact path match. Returns -1 if not found.
int32_t perform_path_lookup(
    const uint8_t* data_ptr,
    size_t item_base_offset,
    size_t item_record_size,
    size_t count,
    const char* target_path,
    size_t target_len
);

#ifdef __cplusplus
}
#endif

#endif /* CSearch_h */
