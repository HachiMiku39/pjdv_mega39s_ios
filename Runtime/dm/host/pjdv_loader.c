// PJDV sparse signed mapping adapter; reused symbol/relocation code retains MIT license.
#include "dm.h"
#include "hle.h"
#include "GuestLayout.h"
#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h>
#include <inttypes.h>
extern size_t pjdv_guest_count(void);
extern void *pjdv_guest_base(size_t);
extern const pjdv_guest_layout *pjdv_guest_layout_at(size_t);
extern pthread_key_t pjdv_guest_key(unsigned);
module_t g_mod[MAX_MOD];
int g_nmod;
pthread_key_t g_key18, g_keytls, g_keytlr, g_keygate;
pthread_key_t g_keyres[2], g_keyaspect, g_keyaspectui;   // g_keyaspect：宽高比上限参数位（KASPECT）          // 分辨率参数位（改写器 PARAMS，KRES0 掌机 / KRES1 主机）；产物没有即 0、不占 | g_keyaspect: aspect ratio upper-limit parameter slot (KASPECT)          // resolution parameter slots (rewriter PARAMS, KRES0 handheld / KRES1 docked); 0 and not allocated if the build output lacks them
enum { KEY_K18, KEY_KTLS, KEY_KTLR, KEY_KGATE, KEY_KRES0, KEY_KRES1, KEY_KASPECT, KEY_KASPECTUI, KEY_N };

uint64_t resolve_import(module_t *m, const char *name);
void gate_register(uint64_t ret_addr, const char *kind, int arg, uint64_t orig);

static void build_symhash(module_t *m);
static void parse_dynamic(module_t *m) {
    uint32_t mod0 = *(uint32_t *)(m->base + 4);
    if (memcmp(m->base + mod0, "MOD0", 4)) die("%s: no MOD0", m->name);
    m->dyn = (const Elf64_Dyn *)(m->base + mod0 + *(int32_t *)(m->base + mod0 + 4));
    for (const Elf64_Dyn *d = m->dyn; d->d_tag; d++) switch (d->d_tag) {
        case DT_SYMTAB: m->symtab = (const Elf64_Sym *)(m->base + d->d_un.d_ptr); break;
        case DT_STRTAB: m->strtab = (const char *)(m->base + d->d_un.d_ptr); break;
        case DT_INIT: m->init = d->d_un.d_ptr; break;
        case DT_INIT_ARRAY: m->init_array = d->d_un.d_ptr; break;
        case DT_INIT_ARRAYSZ: m->init_arraysz = d->d_un.d_val; break;
    }
    m->nsym = (unsigned)(((const uint8_t *)m->strtab - (const uint8_t *)m->symtab) / sizeof(Elf64_Sym));
    build_symhash(m);
}

static void *module_sym_linear(module_t *m, const char *name) {
    for (unsigned i = 1; i < m->nsym; i++) {
        const Elf64_Sym *s = &m->symtab[i];
        if (s->st_shndx && !strcmp(m->strtab + s->st_name, name)) return m->base + s->st_value;
    }
    return NULL;
}
// 符号名哈希表：按下标升序插入、同名已在则不覆盖 ⇒ 查询结果与线性扫描（首个已定义同名符号）逐条相同。
// ① 宿主装载 91–99 ms 里重定位 + 强制接管占 77–86 ms，主因是每条按名解析的重定位都线性扫两个模块的符号表
// Symbol name hash table: inserted in ascending index order, not overwritten if the same name is already there ⇒ lookup results are identical, entry by entry, to a linear scan (the first defined symbol with that name).
// Of the 91–99 ms of ① host loading, relocation + forced take-over took 77–86 ms, mainly because every by-name relocation scanned the symbol tables of two modules linearly
static uint32_t sym_hash(const char *s) { uint32_t h = 2166136261u; while (*s) h = (h ^ (uint8_t)*s++) * 16777619u; return h; }
static void build_symhash(module_t *m) {
    unsigned cap = 16; while (cap < m->nsym * 2) cap <<= 1;
    m->symh = calloc(cap, sizeof *m->symh); m->symh_mask = cap - 1;
    for (unsigned i = 1; i < m->nsym; i++) {
        const Elf64_Sym *s = &m->symtab[i]; if (!s->st_shndx) continue;
        const char *nm = m->strtab + s->st_name;
        for (unsigned j = sym_hash(nm) & m->symh_mask;; j = (j + 1) & m->symh_mask) {
            if (!m->symh[j]) { m->symh[j] = i; break; }
            if (!strcmp(m->strtab + m->symtab[m->symh[j]].st_name, nm)) break;   // 同名已有更小下标：保留它 | The same name already exists with a smaller index: keep that one
        }
    }
}
static unsigned long g_symchk_n, g_symchk_bad;
void *module_sym(module_t *m, const char *name) {
    unsigned long nq; (void)nq;
    if (!m->symh) return module_sym_linear(m, name);
    void *r = NULL;
    for (unsigned j = sym_hash(name) & m->symh_mask; m->symh[j]; j = (j + 1) & m->symh_mask) {
        const Elf64_Sym *s = &m->symtab[m->symh[j]];
        if (!strcmp(m->strtab + s->st_name, name)) { r = m->base + s->st_value; break; }
    }
    static int chk = -1; if (chk < 0) chk = getenv("DM_SYMCHECK") != NULL;
    if (chk) { void *l = module_sym_linear(m, name); g_symchk_n++; nq = g_symchk_n;
               if (l != r) { g_symchk_bad++; LOG("【红】DM_SYMCHECK：%s 在 %s 哈希 %p ≠ 线性 %p", name, m->name, r, l); } }
    return r;
}
void *guest_sym(const char *name) {
    for (int i = 0; i < g_nmod; i++) { void *p = module_sym(&g_mod[i], name); if (p) return p; }
    return NULL;
}
module_t *module_of(const void *p) {
    for (int i = 0; i < g_nmod; i++)
        if ((uintptr_t)p >= (uintptr_t)g_mod[i].base - 0x400000 && (const uint8_t *)p < g_mod[i].base + g_mod[i].size) return &g_mod[i];
    return NULL;
}

// 跨模块符号解析：先在已装模块里找定义，找不到再交给 HLE / 桩
// Cross-module symbol resolution: first look for a definition in the loaded modules, and only if not found hand over to HLE / stubs
static uint64_t resolve_sym(module_t *m, const char *name) {
    for (int i = 0; i < g_nmod; i++) { void *p = module_sym(&g_mod[i], name); if (p) return (uint64_t)p; }
    return resolve_import(m, name);
}

// 强制接管表（hle.h HLE_FORCE，__DATA,swforce 段）：命中即覆盖模块内定义
// Forced take-over table (hle.h HLE_FORCE, the __DATA,swforce section): a hit overrides the definition inside the module
static const hle_force_ent *g_force; static unsigned g_nforce; static unsigned *g_force_hits;
static void force_init(void) {
    unsigned long sz; g_force = (const hle_force_ent *)getsectiondata(&_mh_execute_header, "__DATA", "swforce", &sz);
    g_nforce = g_force ? (unsigned)(sz / sizeof *g_force) : 0;
    g_force_hits = calloc(g_nforce + 1, sizeof *g_force_hits);
    for (unsigned i = 0; i < g_nforce; i++)
        for (unsigned j = i + 1; j < g_nforce; j++)
            if (!strcmp(g_force[i].name, g_force[j].name)) die("强制接管清单重复：%s", g_force[i].name);
}
static void *force_lookup(const char *name) {
    for (unsigned i = 0; i < g_nforce; i++)
        if (!strcmp(g_force[i].name, name)) {
            if (!g_force_hits[i]++ && g_flag.imports) LOG("force %s  （%s）", name, g_force[i].why);
            void *hlecount_wrap(const char *, const char *, void *); return hlecount_wrap("FORCE", name, g_force[i].fn);   // DM_HLECOUNT 时为计数桩 | A counting stub when DM_HLECOUNT is set
        }
    return NULL;
}
static void relocate(module_t *m) {
    uint64_t rela = 0, relasz = 0, jmprel = 0, pltsz = 0;
    for (const Elf64_Dyn *d = m->dyn; d->d_tag; d++) switch (d->d_tag) {
        case DT_RELA: rela = d->d_un.d_ptr; break;
        case DT_RELASZ: relasz = d->d_un.d_val; break;
        case DT_JMPREL: jmprel = d->d_un.d_ptr; break;
        case DT_PLTRELSZ: pltsz = d->d_un.d_val; break;
    }
    int cnt[3] = {0};
    const Elf64_Rela *tabs[2] = {(const Elf64_Rela *)(m->base + rela), (const Elf64_Rela *)(m->base + jmprel)};
    uint64_t sizes[2] = {relasz, pltsz};
    for (int t = 0; t < 2; t++)
        for (uint64_t i = 0; i < sizes[t] / sizeof(Elf64_Rela); i++) {
            const Elf64_Rela *r = &tabs[t][i];
            if (r->r_offset < ((m->text_end+0x3fff)&~0x3fffull) ||
                r->r_offset > m->key_page_off-8) die("%s: relocation target outside writable memory",m->name);
            uint64_t *where = (uint64_t *)(m->base + r->r_offset);
            unsigned type = ELF64_R_TYPE(r->r_info), si = ELF64_R_SYM(r->r_info);
            if (type == R_AARCH64_RELATIVE) { *where = (uint64_t)m->base + r->r_addend; cnt[0]++; continue; }
            if (type!=R_AARCH64_ABS64 && type!=R_AARCH64_GLOB_DAT && type!=R_AARCH64_JUMP_SLOT)
                die("%s: unsupported relocation %u",m->name,type);
            if(si>=m->nsym)die("%s: symbol index outside table",m->name);
            const Elf64_Sym *s = &m->symtab[si];
            uint64_t v = (uint64_t)force_lookup(m->strtab + s->st_name);
            if (!v && !s->st_shndx && (s->st_info>>4)==2) v = 0;
            else if (!v) v = s->st_shndx ? (uint64_t)m->base + s->st_value : resolve_sym(m, m->strtab + s->st_name);
            if (type == R_AARCH64_JUMP_SLOT) { *where = v; cnt[2]++; }
            else { *where = v + r->r_addend; cnt[1]++; }       // ABS64 / GLOB_DAT
        }
    LOG("%s: reloc relative=%d abs/glob=%d jump=%d", m->name, cnt[0], cnt[1], cnt[2]);
}


void pjdv_guest_relocate(void) {
    size_t count=pjdv_guest_count();if(!count || count>MAX_MOD)die("Guest images missing");
    g_key18=pjdv_guest_key(0);g_keytls=pjdv_guest_key(1);g_keytlr=pjdv_guest_key(2);g_keygate=pjdv_guest_key(3);
    g_keyres[0]=pjdv_guest_key(4);g_keyres[1]=pjdv_guest_key(5);g_keyaspect=pjdv_guest_key(6);g_keyaspectui=pjdv_guest_key(7);
    // Verify actual pthread TSD layout on the guest execution thread.
    pthread_setspecific(g_key18,(void *)0x1234);uint64_t tsd;
    __asm__ volatile("mrs %0,tpidrro_el0":"=r"(tsd));
    if(((uint64_t *)(tsd&~7ull))[g_key18]!=0x1234)die("pthread TSD layout mismatch");
    pthread_setspecific(g_key18,NULL);
    for(size_t i=0;i<count;i++) {
        module_t *m=&g_mod[i];const pjdv_guest_layout *l=pjdv_guest_layout_at(i);
        strlcpy(m->name,l->name,sizeof m->name);m->base=pjdv_guest_base(i);m->size=l->virtual_bytes;
        m->text_end=l->text_end;m->ro_off=l->ro_off;m->data_off=l->data_off;
        m->patch_off=(uint64_t)-(int64_t)l->prefix;m->key_page_off=l->virtual_bytes-0x4000;m->key_page_size=0x4000;
        for(int j=0;j<8;j++)m->key_idx[j]=j;
        parse_dynamic(m);g_nmod++;
    }
    for(size_t i=0;i<sizeof(pjdv_gates)/sizeof(*pjdv_gates);i++) {
        const pjdv_gate_layout *g=&pjdv_gates[i];
        gate_register((uint64_t)g_mod[g->module].base+g->ret,g->kind,g->arg,g->orig);
    }
    force_init();for(int i=0;i<g_nmod;i++)relocate(&g_mod[i]);
    unsigned used=0;for(unsigned i=0;i<g_nforce;i++)used+=g_force_hits[i]!=0;
    LOG("PJDV modules=%d gates=%zu referenced host overrides=%u/%u",g_nmod,sizeof(pjdv_gates)/sizeof(*pjdv_gates),used,g_nforce);
}
void run_module_inits(void) {
    for (int i = 0; i < g_nmod; i++) {
        module_t *m = &g_mod[i];
        if (!m->init) continue;
        LOG("%s: DT_INIT +%#llx（init_array %llu 项）", m->name, m->init, m->init_arraysz / 8);
        ((void (*)(void))(m->base + m->init))();
    }
}

void pjdv_loader_session_end(void) {
    for(int i=0;i<g_nmod;i++)free(g_mod[i].symh);
    memset(g_mod,0,sizeof g_mod);g_nmod=0;
    free(g_force_hits);g_force_hits=NULL;g_nforce=0;g_force=NULL;
}
