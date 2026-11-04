// 验证 roothide 的 jbroot() 映射，以及 CCSIMTool 的两个候选路径在本机是否可达。
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <unistd.h>

typedef char *(*jbroot_fn)(const char *);

int main(void)
{
    @autoreleasepool {
        const char *cands[] = {
            "/var/jb/usr/local/bin/CCSIMTool",
            "/usr/local/bin/CCSIMTool",
            "/Library/ControlCenter/Bundles/CCSIM.bundle/CCSIM",
        };
        for (size_t i = 0; i < sizeof(cands) / sizeof(cands[0]); i++)
            printf("access(X_OK) %-52s = %d\n", cands[i], access(cands[i], X_OK));

        void *h = dlopen("/usr/lib/libroothide.dylib", RTLD_LAZY);
        printf("libroothide handle = %p (%s)\n", h, h ? "ok" : dlerror());
        jbroot_fn jb = h ? (jbroot_fn)dlsym(h, "jbroot") : NULL;
        printf("jbroot symbol = %p\n", (void *)jb);
        if (jb) {
            char *m = jb("/usr/local/bin/CCSIMTool");
            printf("jbroot(/usr/local/bin/CCSIMTool) = %s (X_OK=%d)\n",
                   m ? m : "(null)", m ? access(m, X_OK) : -1);
        }
    }
    return 0;
}
