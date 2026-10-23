#import <QuartzCore/CAMetalLayer.h>
static CAMetalLayer *gameLayer;
void pjdv_attach_metal_layer(void *layer){gameLayer=(__bridge CAMetalLayer *)layer;}
void *front_metal_layer(void){return (__bridge void *)gameLayer;}

#include <stdatomic.h>
static _Atomic int graphicsActive;
extern void pjdv_monitor_reset(void);
void pjdv_begin_game_graphics(void){if(!atomic_exchange(&graphicsActive,1))pjdv_monitor_reset();}
int pjdv_game_graphics_active(void){return atomic_load(&graphicsActive);}

void pjdv_end_game_graphics(void){atomic_store(&graphicsActive,0);gameLayer=nil;}
