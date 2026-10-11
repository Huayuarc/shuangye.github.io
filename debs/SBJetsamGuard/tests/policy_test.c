/* Pure policy tests: no Darwin APIs and no system mutation. */
#include "../Policy.h"
#include <assert.h>
#include <limits.h>
#include <stdio.h>
static unsigned checks;
#define CHECK(x) do { ++checks; if (!(x)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x); return 1; } } while (0)
int main(void) {
 const uint64_t M=1024ULL*1024ULL;
 const struct { uint64_t ram; int32_t expected; } cases[]={
  {0,0},{2048*M-1,0},{2048*M,2048},{3072*M,2048},{4096*M,2048},
  {6144*M,2048},{8192*M,2048},{UINT64_MAX,2048}
 };
 CHECK(sizeof(SJGLimits)==16);
 CHECK(offsetof(SJGLimits,active)==0 && offsetof(SJGLimits,active_attr)==4);
 CHECK(offsetof(SJGLimits,inactive)==8 && offsetof(SJGLimits,inactive_attr)==12);
 for(size_t i=0;i<sizeof(cases)/sizeof(cases[0]);i++) CHECK(sjg_target(cases[i].ram)==cases[i].expected);
 const int32_t values[]={INT32_MIN,-1,0,1,511,512,513,1536,INT32_MAX};
 for(size_t i=0;i<9;i++) for(size_t j=0;j<9;j++) for(unsigned a=0;a<2;a++) for(unsigned b=0;b<2;b++) {
  SJGLimits old={values[i],a,values[j],b},out,second;
  int32_t ea=old.active>0 && old.active<512 ? 512:old.active;
  int32_t ei=old.inactive>0 && old.inactive<512 ? 512:old.inactive;
  bool changed=sjg_plan(old,512,&out);
  CHECK(out.active==ea && out.inactive==ei);
  CHECK(out.active_attr==a && out.inactive_attr==b);
  CHECK(changed==(ea!=old.active || ei!=old.inactive));
  CHECK(!sjg_plan(out,512,&second) && sjg_equal(second,out));
  CHECK(!sjg_plan(old,0,&out) && sjg_equal(old,out));
  CHECK(!sjg_plan(old,-1,&out) && sjg_equal(old,out));
 }
 for(unsigned bit=1;bit<32;bit++) {
  SJGLimits old={128,1u<<bit,256,1},out;
  CHECK(!sjg_plan(old,1024,&out) && sjg_equal(old,out));
  old.active_attr=1;old.inactive_attr=1u<<bit;
  CHECK(!sjg_plan(old,1024,&out) && sjg_equal(old,out));
 }
 SJGLimits base={100,0,200,1},other=base;
 CHECK(sjg_equal(base,other));other.active++;CHECK(!sjg_equal(base,other));
 other=base;other.inactive++;CHECK(!sjg_equal(base,other));
 other=base;other.active_attr^=1;CHECK(!sjg_equal(base,other));
 other=base;other.inactive_attr^=1;CHECK(!sjg_equal(base,other));
 printf("policy: %u checks PASS (324 state/attribute combinations)\n",checks);
 return 0;
}
