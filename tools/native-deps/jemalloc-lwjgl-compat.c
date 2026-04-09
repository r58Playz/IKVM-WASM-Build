#include <stddef.h>

void je_free(void *ptr);

void je_free_sized(void *ptr, size_t size) {
    (void)size;
    je_free(ptr);
}

void je_free_aligned_sized(void *ptr, size_t alignment, size_t size) {
    (void)alignment;
    (void)size;
    je_free(ptr);
}
