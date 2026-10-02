#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
static double now_ms(void){static unsigned ticks;if(getenv("BENCH_SMOKE") && !strcmp(getenv("BENCH_SMOKE"),"1"))return ++ticks;struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1000.0+t.tv_nsec/1e6;}
int main(int argc,char**argv){if(argc!=2)return 2;int nullfd=open("/dev/null",O_WRONLY);int reps=getenv("BENCH_SMOKE") && !strcmp(getenv("BENCH_SMOKE"),"1")?1:500; double start=now_ms();for(int i=0;i<reps;i++){pid_t p=fork();if(p==0){dup2(nullfd,1);execlp(getenv("TAIL")?getenv("TAIL"):"tail","tail","-n",reps==1?"1":"1000",argv[1],(char*)0);_exit(127);}int status;waitpid(p,&status,0);if(!WIFEXITED(status)||WEXITSTATUS(status))return 1;}double elapsed=(now_ms()-start)/reps;printf("bsd-tail\ttail-1000\tlatency\t%.6f\tms\n",elapsed);return 0;}
