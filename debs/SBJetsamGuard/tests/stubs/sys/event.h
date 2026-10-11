#ifndef SJG_TEST_EVENT_H
#define SJG_TEST_EVENT_H
#include <stdint.h>
#include <time.h>
struct kevent { uintptr_t ident; int16_t filter; uint16_t flags; uint32_t fflags; intptr_t data; void *udata; };
#define EVFILT_PROC (-5)
#define EV_ADD 0x0001
#define EV_DELETE 0x0002
#define EV_ONESHOT 0x0010
#define NOTE_EXIT 0x80000000u
#define EV_SET(e,a,b,c,d,f,g) do { *(e)=(struct kevent){(a),(b),(c),(d),(f),(g)}; } while (0)
int kqueue(void);
int kevent(int, const struct kevent *, int, struct kevent *, int, const struct timespec *);
#endif
