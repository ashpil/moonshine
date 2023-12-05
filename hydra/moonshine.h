#pragma once

typedef struct HdMoonshine HdMoonshine;
extern "C" HdMoonshine* HdMoonshineCreate(void);
extern "C" void HdMoonshineDestroy(HdMoonshine*);
extern "C" void HdMoonshineRender(HdMoonshine*, float*);
