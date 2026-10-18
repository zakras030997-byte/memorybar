#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/ps/IOPowerSources.h>
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <sys/socket.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/route.h>
#include <libproc.h>

static void network(NSMutableDictionary *out) {
    int mib[]={CTL_NET,PF_ROUTE,0,0,NET_RT_IFLIST2,0};
    size_t length=0;
    if(sysctl(mib,6,NULL,&length,NULL,0)!=0) return;
    char *buffer=malloc(length);
    if(!buffer) return;
    if(sysctl(mib,6,buffer,&length,NULL,0)!=0) { free(buffer); return; }
    uint64_t rx=0, tx=0, ip=0, op=0;
    NSMutableArray *names=[NSMutableArray array];
    for(char *p=buffer;p<buffer+length;) {
        struct if_msghdr *head=(struct if_msghdr *)p;
        if(head->ifm_msglen==0 || p+head->ifm_msglen>buffer+length) break;
        p+=head->ifm_msglen;
        if(head->ifm_type!=RTM_IFINFO2 || head->ifm_msglen<sizeof(struct if_msghdr2)) continue;
        struct if_msghdr2 *info=(struct if_msghdr2 *)head;
        char name[IF_NAMESIZE]={0};
        if(!if_indextoname(info->ifm_index,name)) continue;
        // Count physical interfaces once. Tunnel and bridge counters would double-count VPN traffic.
        if(strncmp(name,"en",2)!=0) continue;
        struct if_data64 *d=&info->ifm_data;
        rx+=d->ifi_ibytes; tx+=d->ifi_obytes; ip+=d->ifi_ipackets; op+=d->ifi_opackets;
        [names addObject:@(name)];
    }
    free(buffer);
    out[@"network"]=@{@"rx":@(rx),@"tx":@(tx),@"inPackets":@(ip),@"outPackets":@(op),@"interfaces":names};
}

static void disk(NSMutableDictionary *out) {
    io_iterator_t it=0;
    if(IOServiceGetMatchingServices(kIOMainPortDefault,IOServiceMatching("IOBlockStorageDriver"),&it)!=KERN_SUCCESS) return;
    uint64_t read=0,write=0,reads=0,writes=0; unsigned count=0;
    io_object_t obj;
    while((obj=IOIteratorNext(it))) {
        CFTypeRef value=IORegistryEntryCreateCFProperty(obj,CFSTR("Statistics"),kCFAllocatorDefault,0);
        if(value && CFGetTypeID(value)==CFDictionaryGetTypeID()) {
            NSDictionary *d=(__bridge NSDictionary *)value;
            if(d[@"Bytes (Read)"] && d[@"Bytes (Write)"]) {
                read+=[d[@"Bytes (Read)"] unsignedLongLongValue]; write+=[d[@"Bytes (Write)"] unsignedLongLongValue];
                reads+=[d[@"Operations (Read)"] unsignedLongLongValue]; writes+=[d[@"Operations (Write)"] unsignedLongLongValue]; count++;
            }
        }
        if(value) CFRelease(value);
        IOObjectRelease(obj);
    }
    IOObjectRelease(it);
    if(count) out[@"disk"]=@{@"read":@(read),@"write":@(write),@"reads":@(reads),@"writes":@(writes),@"devices":@(count)};
}

static void battery(NSMutableDictionary *out) {
    CFTypeRef blob=IOPSCopyPowerSourcesInfo();
    if(!blob) return;
    CFArrayRef sources=IOPSCopyPowerSourcesList(blob);
    if(sources) {
        for(CFIndex i=0;i<CFArrayGetCount(sources);i++) {
            CFDictionaryRef desc=IOPSGetPowerSourceDescription(blob,CFArrayGetValueAtIndex(sources,i));
            if(!desc) continue;
            NSDictionary *d=(__bridge NSDictionary *)desc;
            if(![d[@"Type"] isEqual:@"InternalBattery"]) continue;
            double max=[d[@"Max Capacity"] doubleValue];
            NSMutableDictionary *b=[@{@"percent":@(max>0 ? [d[@"Current Capacity"] doubleValue]/max*100:0),
                @"charging":d[@"Is Charging"]?:@NO,@"power":d[@"Power Source State"]?:@"Unknown",
                @"toFull":d[@"Time to Full Charge"]?:@(-1),@"toEmpty":d[@"Time to Empty"]?:@(-1)} mutableCopy];
            io_service_t svc=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSmartBattery"));
            if(svc) {
                CFMutableDictionaryRef props=NULL;
                if(IORegistryEntryCreateCFProperties(svc,&props,kCFAllocatorDefault,0)==KERN_SUCCESS) {
                    NSDictionary *p=(__bridge NSDictionary *)props;
                    NSNumber *amps=p[@"InstantAmperage"]?:p[@"Amperage"];
                    NSNumber *volts=p[@"Voltage"];
                    if(amps && volts) {
                        // Some drivers encode a signed current in an unsigned 64-bit NSNumber.
                        int64_t ma=[amps longLongValue];
                        if(llabs(ma)<100000) b[@"watts"]=@(fabs((double)ma*[volts doubleValue]/1000000));
                    }
                    if(p[@"CycleCount"]) b[@"cycles"]=p[@"CycleCount"];
                    CFRelease(props);
                }
                IOObjectRelease(svc);
            }
            out[@"battery"]=b; break;
        }
        CFRelease(sources);
    }
    CFRelease(blob);
}

char *mb_snapshot(void) {
 @autoreleasepool {
    NSMutableDictionary *out=[NSMutableDictionary dictionary];
    out[@"time"]=@([[NSDate date] timeIntervalSince1970]);
    out[@"totalMemory"]=@([NSProcessInfo processInfo].physicalMemory);
    mach_port_t host=mach_host_self();
    vm_statistics64_data_t vm={0}; mach_msg_type_number_t count=HOST_VM_INFO64_COUNT;
    if(host_statistics64(host,HOST_VM_INFO64,(host_info64_t)&vm,&count)==KERN_SUCCESS) {
        vm_size_t page=0; host_page_size(host,&page);
        uint64_t reclaim=((uint64_t)vm.purgeable_count+vm.external_page_count)*page;
        uint64_t occupied=((uint64_t)vm.active_count+vm.inactive_count+vm.wire_count+vm.compressor_page_count)*page;
        out[@"memory"]=@{@"used":@(occupied>reclaim?occupied-reclaim:0),@"wired":@((uint64_t)vm.wire_count*page),
            @"compressed":@((uint64_t)vm.compressor_page_count*page),@"cached":@(reclaim)};
    }
    struct xsw_usage swap={0}; size_t len=sizeof(swap);
    if(sysctlbyname("vm.swapusage",&swap,&len,NULL,0)==0) out[@"swap"]=@(swap.xsu_used);
    host_cpu_load_info_data_t cpu={0}; count=HOST_CPU_LOAD_INFO_COUNT;
    if(host_statistics(host,HOST_CPU_LOAD_INFO,(host_info_t)&cpu,&count)==KERN_SUCCESS)
        out[@"cpu"]=@[@(cpu.cpu_ticks[CPU_STATE_USER]),@(cpu.cpu_ticks[CPU_STATE_SYSTEM]),@(cpu.cpu_ticks[CPU_STATE_IDLE]),@(cpu.cpu_ticks[CPU_STATE_NICE])];
    mach_port_deallocate(mach_task_self(),host);
    // Obtain process count without collecting process names or command-line arguments.
    int n=proc_listallpids(NULL,0);
    if(n>0) {
        pid_t *pids=calloc(n+128,sizeof(pid_t));
        int actual=proc_listallpids(pids,(n+128)*(int)sizeof(pid_t));
        if(actual>0) out[@"processes"]=@(actual);
        free(pids);
    }
    struct loadavg load; len=sizeof(load);
    if(sysctlbyname("vm.loadavg",&load,&len,NULL,0)==0) out[@"load"]=@((double)load.ldavg[0]/load.fscale);
    network(out); disk(out); battery(out);
    NSData *data=[NSJSONSerialization dataWithJSONObject:out options:0 error:NULL];
    return data ? strndup(data.bytes,data.length) : strdup("{}");
 }
}
