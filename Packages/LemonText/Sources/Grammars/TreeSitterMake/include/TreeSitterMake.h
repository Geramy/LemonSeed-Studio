#ifndef TREESITTERMAKE_H
#define TREESITTERMAKE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TSLanguage TSLanguage;
const TSLanguage *tree_sitter_make(void);

#ifdef __cplusplus
}
#endif

#endif
