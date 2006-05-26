/* classes: h_files */

#ifndef SCM_GC_H
#define SCM_GC_H

/* Copyright (C) 1995,1996,1998,1999,2000,2001, 2002, 2003, 2004, 2006 Free Software Foundation, Inc.
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */



#include "libguile/__scm.h"

#include "libguile/hooks.h"
#include "libguile/threads.h"


typedef struct scm_t_cell
{
  SCM word_0;
  SCM word_1;
} scm_t_cell;

/* Cray machines have pointers that are incremented once for each
 * word, rather than each byte, the 3 most significant bits encode the
 * byte within the word.  The following macros deal with this by
 * storing the native Cray pointers like the ones that looks like scm
 * expects.  This is done for any pointers that point to a cell,
 * pointers to scm_vector elts, functions, &c are not munged.
 */
#ifdef _UNICOS
#  define SCM2PTR(x) ((scm_t_cell *) (SCM_UNPACK (x) >> 3))
#  define PTR2SCM(x) (SCM_PACK (((scm_t_bits) (x)) << 3))
#else
#  define SCM2PTR(x) ((scm_t_cell *) (SCM_UNPACK (x)))
#  define PTR2SCM(x) (SCM_PACK ((scm_t_bits) (x)))
#endif /* def _UNICOS */



/* Low level cell data accessing macros.  These macros should only be used
 * from within code related to garbage collection issues, since they will
 * never check the cells they are applied to - not even if guile is compiled
 * in debug mode.  In particular these macros will even work for free cells,
 * which should never be encountered by user code.  */

#define SCM_GC_CELL_OBJECT(x, n) (((SCM *)SCM2PTR (x)) [n])
#define SCM_GC_CELL_WORD(x, n)   (SCM_UNPACK (SCM_GC_CELL_OBJECT ((x), (n))))

#define SCM_GC_SET_CELL_OBJECT(x, n, v) ((((SCM *)SCM2PTR (x)) [n]) = (v))
#define SCM_GC_SET_CELL_WORD(x, n, v)  \
  (SCM_GC_SET_CELL_OBJECT ((x), (n), SCM_PACK (v)))

#define SCM_GC_CELL_TYPE(x) (SCM_GC_CELL_OBJECT ((x), 0))


/* Except for the garbage collector, no part of guile should ever run over a
 * free cell.  Thus, if guile is compiled in debug mode the SCM_CELL_* and
 * SCM_SET_CELL_* macros below report an error if they are applied to a free
 * cell.  Some other plausibility checks are also performed.  However, if
 * guile is not compiled in debug mode, there won't be any time penalty at all
 * when using these macros.  */

#if (SCM_DEBUG_CELL_ACCESSES == 1)
#  define SCM_VALIDATE_CELL(cell, expr) (scm_assert_cell_valid (cell), (expr))
#else
#  define SCM_VALIDATE_CELL(cell, expr) (expr)
#endif

#define SCM_CELL_WORD(x, n) \
  SCM_VALIDATE_CELL ((x), SCM_GC_CELL_WORD ((x), (n)))
#define SCM_CELL_WORD_0(x) SCM_CELL_WORD ((x), 0)
#define SCM_CELL_WORD_1(x) SCM_CELL_WORD ((x), 1)
#define SCM_CELL_WORD_2(x) SCM_CELL_WORD ((x), 2)
#define SCM_CELL_WORD_3(x) SCM_CELL_WORD ((x), 3)

#define SCM_CELL_OBJECT(x, n) \
  SCM_VALIDATE_CELL ((x), SCM_GC_CELL_OBJECT ((x), (n)))
#define SCM_CELL_OBJECT_0(x) SCM_CELL_OBJECT ((x), 0)
#define SCM_CELL_OBJECT_1(x) SCM_CELL_OBJECT ((x), 1)
#define SCM_CELL_OBJECT_2(x) SCM_CELL_OBJECT ((x), 2)
#define SCM_CELL_OBJECT_3(x) SCM_CELL_OBJECT ((x), 3)

#define SCM_SET_CELL_WORD(x, n, v) \
  SCM_VALIDATE_CELL ((x), SCM_GC_SET_CELL_WORD ((x), (n), (v)))
#define SCM_SET_CELL_WORD_0(x, v) SCM_SET_CELL_WORD ((x), 0, (v))
#define SCM_SET_CELL_WORD_1(x, v) SCM_SET_CELL_WORD ((x), 1, (v))
#define SCM_SET_CELL_WORD_2(x, v) SCM_SET_CELL_WORD ((x), 2, (v))
#define SCM_SET_CELL_WORD_3(x, v) SCM_SET_CELL_WORD ((x), 3, (v))

#define SCM_SET_CELL_OBJECT(x, n, v) \
  SCM_VALIDATE_CELL ((x), SCM_GC_SET_CELL_OBJECT ((x), (n), (v)))
#define SCM_SET_CELL_OBJECT_0(x, v) SCM_SET_CELL_OBJECT ((x), 0, (v))
#define SCM_SET_CELL_OBJECT_1(x, v) SCM_SET_CELL_OBJECT ((x), 1, (v))
#define SCM_SET_CELL_OBJECT_2(x, v) SCM_SET_CELL_OBJECT ((x), 2, (v))
#define SCM_SET_CELL_OBJECT_3(x, v) SCM_SET_CELL_OBJECT ((x), 3, (v))

#define SCM_CELL_OBJECT_LOC(x, n) (SCM_VALIDATE_CELL((x), &SCM_GC_CELL_OBJECT ((x), (n))))
#define SCM_CARLOC(x)             (SCM_CELL_OBJECT_LOC ((x), 0))
#define SCM_CDRLOC(x)             (SCM_CELL_OBJECT_LOC ((x), 1))

#define SCM_CELL_TYPE(x) SCM_CELL_WORD_0 (x)
#define SCM_SET_CELL_TYPE(x, t) SCM_SET_CELL_WORD_0 ((x), (t))

/* Freelists consist of linked cells where the type entry holds the value
 * scm_tc_free_cell and the second entry holds a pointer to the next cell of
 * the freelist.  Due to this structure, freelist cells are not cons cells
 * and thus may not be accessed using SCM_CAR and SCM_CDR.  */

#define SCM_FREE_CELL_CDR(x) \
  (SCM_GC_CELL_OBJECT ((x), 1))
#define SCM_SET_FREE_CELL_CDR(x, v) \
  (SCM_GC_SET_CELL_OBJECT ((x), 1, (v)))

#if (SCM_DEBUG_CELL_ACCESSES == 1)
/* Set this to != 0 if every cell that is accessed shall be checked:
 */
SCM_API int scm_debug_cell_accesses_p;
SCM_API int scm_expensive_debug_cell_accesses_p;
SCM_API int scm_debug_cells_gc_interval ;
void scm_i_expensive_validation_check (SCM cell);
#endif

SCM_API scm_i_pthread_mutex_t scm_i_gc_admin_mutex;

#define scm_gc_running_p (SCM_I_CURRENT_THREAD->gc_running_p)
SCM_API scm_i_pthread_mutex_t scm_i_sweep_mutex;



#if (SCM_ENABLE_DEPRECATED == 1)
SCM_API size_t scm_default_init_heap_size_1;
SCM_API int scm_default_min_yield_1;
SCM_API size_t scm_default_init_heap_size_2;
SCM_API int scm_default_min_yield_2;
SCM_API size_t scm_default_max_segment_size;
#else
#define  scm_default_init_heap_size_1 deprecated
#define  scm_default_min_yield_1 deprecated
#define  scm_default_init_heap_size_2 deprecated
#define  scm_default_min_yield_2 deprecated
#define  scm_default_max_segment_size deprecated
#endif


SCM_API size_t scm_max_segment_size;

#define SCM_SET_FREELIST_LOC(key,ptr) scm_i_pthread_setspecific ((key), (ptr))
#define SCM_FREELIST_LOC(key) ((SCM *) scm_i_pthread_getspecific (key))
SCM_API scm_i_pthread_key_t scm_i_freelist;
SCM_API scm_i_pthread_key_t scm_i_freelist2;
SCM_API struct scm_t_cell_type_statistics scm_i_master_freelist;
SCM_API struct scm_t_cell_type_statistics scm_i_master_freelist2;


SCM_API unsigned long scm_gc_cells_swept;
SCM_API unsigned long scm_gc_cells_collected;
SCM_API unsigned long scm_gc_malloc_collected;
SCM_API unsigned long scm_gc_ports_collected;
SCM_API unsigned long scm_cells_allocated;
SCM_API int scm_gc_cell_yield_percentage;
SCM_API int scm_gc_malloc_yield_percentage;
SCM_API unsigned long scm_mallocated;
SCM_API unsigned long scm_mtrigger;



SCM_API SCM scm_after_gc_hook;

SCM_API scm_t_c_hook scm_before_gc_c_hook;
SCM_API scm_t_c_hook scm_before_mark_c_hook;
SCM_API scm_t_c_hook scm_before_sweep_c_hook;
SCM_API scm_t_c_hook scm_after_sweep_c_hook;
SCM_API scm_t_c_hook scm_after_gc_c_hook;

#if defined (GUILE_DEBUG) || defined (GUILE_DEBUG_FREELIST)
#if (SCM_ENABLE_DEPRECATED == 1)
SCM scm_map_free_list (void);
#else
#define scm_map_free_list deprecated
#define scm_free_list_length deprecated
#endif
#endif

#if (SCM_ENABLE_DEPRECATED == 1) && defined (GUILE_DEBUG_FREELIST)
SCM_API SCM scm_gc_set_debug_check_freelist_x (SCM flag);
#endif


#if (SCM_DEBUG_CELL_ACCESSES == 1)
SCM_API void scm_assert_cell_valid (SCM);
#endif

SCM_API SCM scm_set_debug_cell_accesses_x (SCM flag);


SCM_API SCM scm_object_address (SCM obj);
SCM_API SCM scm_gc_stats (void);
SCM_API SCM scm_gc_live_object_stats (void);
SCM_API SCM scm_gc (void);
SCM_API void scm_gc_for_alloc (struct scm_t_cell_type_statistics *freelist);
SCM_API SCM scm_gc_for_newcell (struct scm_t_cell_type_statistics *master, SCM *freelist);
SCM_API void scm_i_gc (const char *what);
SCM_API void scm_gc_mark (SCM p);
SCM_API int scm_in_heap_p (SCM value);
SCM_API void scm_gc_sweep (void);

SCM_API void *scm_malloc (size_t size);
SCM_API void *scm_calloc (size_t size);
SCM_API void *scm_realloc (void *mem, size_t size);
SCM_API char *scm_strdup (const char *str);
SCM_API char *scm_strndup (const char *str, size_t n);
SCM_API void scm_gc_register_collectable_memory (void *mem, size_t size,
						 const char *what);
SCM_API void scm_gc_unregister_collectable_memory (void *mem, size_t size,
						   const char *what);
SCM_API void *scm_gc_malloc_pointerless (size_t size, const char *what);
SCM_API void *scm_gc_calloc (size_t size, const char *what);
SCM_API void *scm_gc_malloc (size_t size, const char *what);
SCM_API void *scm_gc_realloc (void *mem, size_t old_size, 
			      size_t new_size, const char *what);
SCM_API void scm_gc_free (void *mem, size_t size, const char *what);
SCM_API char *scm_gc_strdup (const char *str, const char *what);
SCM_API char *scm_gc_strndup (const char *str, size_t n, const char *what);

SCM_API void scm_remember_upto_here_1 (SCM obj);
SCM_API void scm_remember_upto_here_2 (SCM obj1, SCM obj2);
SCM_API void scm_remember_upto_here (SCM obj1, ...);

/* In GCC we can force a reference to an SCM by making it an input to an
   empty asm.  This avoids the code size and slowdown of an actual function
   call.  Unfortunately there doesn't seem to be any way to do the varargs
   scm_remember_upto_here like this.

   __volatile__ ensures nothing will be moved across the asm, and it won't
   be optimized away (or only if proved unreachable).  Constraint "g" can be
   used on all processors and allows any memory or general register (or
   immediate) operand.  The actual asm syntax doesn't matter, we don't want
   to use it, just ensure the operand is still alive.  See "Extended Asm" in
   the GCC manual for more.  */

#ifdef __GNUC__
#define scm_remember_upto_here_1(x)             \
  do {                                          \
    __asm__ __volatile__ ("" : : "g" (x));      \
  } while (0)
#define scm_remember_upto_here_2(x, y)          \
  do {                                          \
    scm_remember_upto_here_1 (x);               \
    scm_remember_upto_here_1 (y);               \
  } while (0)
#endif

SCM_API SCM scm_return_first (SCM elt, ...);
SCM_API int scm_return_first_int (int x, ...);
SCM_API SCM scm_permanent_object (SCM obj);
SCM_API SCM scm_gc_protect_object (SCM obj);
SCM_API SCM scm_gc_unprotect_object (SCM obj);
SCM_API void scm_gc_register_root (SCM *p);
SCM_API void scm_gc_unregister_root (SCM *p);
SCM_API void scm_gc_register_roots (SCM *b, unsigned long n);
SCM_API void scm_gc_unregister_roots (SCM *b, unsigned long n);
SCM_API void scm_storage_prehistory (void);
SCM_API int scm_init_storage (void);
SCM_API void *scm_get_stack_base (void);
SCM_API void scm_init_gc (void);

#if SCM_ENABLE_DEPRECATED == 1

SCM_API SCM scm_deprecated_newcell (void);
SCM_API SCM scm_deprecated_newcell2 (void);

#define SCM_NEWCELL(_into) \
  do { _into = scm_deprecated_newcell (); } while (0)
#define SCM_NEWCELL2(_into) \
  do { _into = scm_deprecated_newcell2 (); } while (0)

SCM_API void * scm_must_malloc (size_t len, const char *what);
SCM_API void * scm_must_realloc (void *where,
				 size_t olen, size_t len,
				 const char *what);
SCM_API char *scm_must_strdup (const char *str);
SCM_API char *scm_must_strndup (const char *str, size_t n);
SCM_API void scm_done_malloc (long size);
SCM_API void scm_done_free (long size);
SCM_API void scm_must_free (void *obj);

#endif

#endif  /* SCM_GC_H */

/*
  Local Variables:
  c-file-style: "gnu"
  End:
*/
