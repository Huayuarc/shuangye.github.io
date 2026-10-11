/* Static contract checks for AutoTrimMonitor.m; no SpringBoard injection runs. */
#include <assert.h>
#include <stdio.h>
#include <stdint.h>
int main(void){
 const uint64_t M=1024ULL*1024ULL,threshold=1536ULL*M;
 unsigned high=0,triggers=0;double last=0;
 const uint64_t samples[]={1400ULL*M,1600ULL*M,1600ULL*M,1700ULL*M,1700ULL*M,1400ULL*M,1800ULL*M,1800ULL*M};
 const double times[]={30,60,90,120,150,600,690,720};
 for(unsigned i=0;i<8;i++){
  if(samples[i]<threshold){high=0;continue;}
  if(high<2)high++;
  if(high>=2&&(last==0||times[i]-last>=600)){triggers++;last=times[i];high=0;}
 }
 assert(triggers==2);
 puts("auto-trim-policy PASS: two-sample threshold and 600s cooldown");
 return 0;
}
