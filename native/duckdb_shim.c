// FFI shim: run a SQL statement against a fresh in-memory DuckDB and return the result as TSV
// (header row + data rows; cells tab-separated, rows newline-separated, NULL -> empty cell).
// Lean parses the TSV. Kept deliberately small: one entry point, the DuckDB C API, no global state.
#include <lean/lean.h>
#include "duckdb.h"
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

typedef struct {
  char *data;
  size_t len, cap;
} buf_t;

static void buf_init(buf_t *b) {
  b->cap = 4096;
  b->len = 0;
  b->data = (char *)malloc(b->cap);
  b->data[0] = 0;
}
static void buf_append(buf_t *b, const char *s) {
  size_t l = strlen(s);
  if (b->len + l + 1 > b->cap) {
    while (b->len + l + 1 > b->cap) {
      b->cap *= 2;
    }
    b->data = (char *)realloc(b->data, b->cap);
  }
  memcpy(b->data + b->len, s, l);
  b->len += l;
  b->data[b->len] = 0;
}

static lean_obj_res io_err(const char *msg) {
  return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(msg)));
}

// lean_duckdb_query_tsv : String -> IO String
LEAN_EXPORT lean_obj_res lean_duckdb_query_tsv(b_lean_obj_arg sql_obj, lean_obj_arg world) {
  (void)world;
  const char *sql = lean_string_cstr(sql_obj);

  duckdb_database db;
  duckdb_connection con;
  duckdb_result result;

  if (duckdb_open(NULL, &db) != DuckDBSuccess) {
    return io_err("duckdb_open failed");
  }
  if (duckdb_connect(db, &con) != DuckDBSuccess) {
    duckdb_close(&db);
    return io_err("duckdb_connect failed");
  }
  if (duckdb_query(con, sql, &result) != DuckDBSuccess) {
    const char *e = duckdb_result_error(&result);
    char msg[2048];
    snprintf(msg, sizeof(msg), "duckdb query error: %s", e ? e : "(unknown)");
    lean_object *err = lean_mk_io_user_error(lean_mk_string(msg));
    duckdb_destroy_result(&result);
    duckdb_disconnect(&con);
    duckdb_close(&db);
    return lean_io_result_mk_error(err);
  }

  idx_t cols = duckdb_column_count(&result);
  idx_t rows = duckdb_row_count(&result);

  buf_t b;
  buf_init(&b);
  for (idx_t c = 0; c < cols; c++) {
    if (c) {
      buf_append(&b, "\t");
    }
    buf_append(&b, duckdb_column_name(&result, c));
  }
  buf_append(&b, "\n");
  for (idx_t r = 0; r < rows; r++) {
    for (idx_t c = 0; c < cols; c++) {
      if (c) {
        buf_append(&b, "\t");
      }
      if (!duckdb_value_is_null(&result, c, r)) {
        char *v = duckdb_value_varchar(&result, c, r);
        if (v) {
          buf_append(&b, v);
          duckdb_free(v);
        }
      }
    }
    buf_append(&b, "\n");
  }

  lean_object *res = lean_mk_string(b.data);
  free(b.data);
  duckdb_destroy_result(&result);
  duckdb_disconnect(&con);
  duckdb_close(&db);
  return lean_io_result_mk_ok(res);
}
