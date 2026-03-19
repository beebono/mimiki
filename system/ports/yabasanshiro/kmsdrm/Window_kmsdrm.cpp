#include "BUILD_OPTIONS.h"
#include "Platform.h"

#include "Window.h"
#include "Shared.h"
#include "Renderer.h"

#include <vulkan/vulkan.h>
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <vector>

void Window::_InitOSWindow()
{
}

void Window::_DeInitOSWindow()
{
}

void Window::_UpdateOSWindow()
{
}

void Window::_InitOSSurface()
{
    VkInstance instance = _renderer->GetVulkanInstance();
    VkPhysicalDevice gpu = _renderer->GetVulkanPhysicalDevice();

    uint32_t displayCount = 0;
    vkGetPhysicalDeviceDisplayPropertiesKHR(gpu, &displayCount, nullptr);
    if (displayCount == 0) {
        fprintf(stderr, "VK_KHR_display: no displays found\n");
        assert(0 && "No Vulkan displays available");
        return;
    }

    std::vector<VkDisplayPropertiesKHR> displayProps(displayCount);
    vkGetPhysicalDeviceDisplayPropertiesKHR(gpu, &displayCount, displayProps.data());

    VkDisplayKHR display = displayProps[0].display;
    fprintf(stderr, "VK_KHR_display: using display '%s' (%ux%u)\n",
            displayProps[0].displayName ? displayProps[0].displayName : "(unnamed)",
            displayProps[0].physicalResolution.width,
            displayProps[0].physicalResolution.height);

    uint32_t modeCount = 0;
    vkGetDisplayModePropertiesKHR(gpu, display, &modeCount, nullptr);
    if (modeCount == 0) {
        fprintf(stderr, "VK_KHR_display: no display modes found\n");
        assert(0 && "No display modes available");
        return;
    }

    std::vector<VkDisplayModePropertiesKHR> modeProps(modeCount);
    vkGetDisplayModePropertiesKHR(gpu, display, &modeCount, modeProps.data());

    VkDisplayModeKHR displayMode = modeProps[0].displayMode;
    _surface_size_x = modeProps[0].parameters.visibleRegion.width;
    _surface_size_y = modeProps[0].parameters.visibleRegion.height;

    fprintf(stderr, "VK_KHR_display: mode %ux%u @ %u mHz\n",
            _surface_size_x, _surface_size_y,
            modeProps[0].parameters.refreshRate);

    uint32_t planeCount = 0;
    vkGetPhysicalDeviceDisplayPlanePropertiesKHR(gpu, &planeCount, nullptr);
    if (planeCount == 0) {
        fprintf(stderr, "VK_KHR_display: no display planes found\n");
        assert(0 && "No display planes available");
        return;
    }

    std::vector<VkDisplayPlanePropertiesKHR> planeProps(planeCount);
    vkGetPhysicalDeviceDisplayPlanePropertiesKHR(gpu, &planeCount, planeProps.data());

    uint32_t planeIndex = UINT32_MAX;
    uint32_t planeStackIndex = 0;

    for (uint32_t i = 0; i < planeCount; i++) {
        if (planeProps[i].currentDisplay != VK_NULL_HANDLE &&
            planeProps[i].currentDisplay != display) {
            continue;
        }

        uint32_t supportedCount = 0;
        vkGetDisplayPlaneSupportedDisplaysKHR(gpu, i, &supportedCount, nullptr);
        if (supportedCount == 0) continue;

        std::vector<VkDisplayKHR> supported(supportedCount);
        vkGetDisplayPlaneSupportedDisplaysKHR(gpu, i, &supportedCount, supported.data());

        for (uint32_t j = 0; j < supportedCount; j++) {
            if (supported[j] == display) {
                planeIndex = i;
                planeStackIndex = planeProps[i].currentStackIndex;
                break;
            }
        }
        if (planeIndex != UINT32_MAX) break;
    }

    if (planeIndex == UINT32_MAX) {
        fprintf(stderr, "VK_KHR_display: no compatible plane found\n");
        assert(0 && "No compatible display plane");
        return;
    }

    fprintf(stderr, "VK_KHR_display: using plane %u (stack %u)\n",
            planeIndex, planeStackIndex);

    VkDisplayPlaneCapabilitiesKHR planeCaps = {};
    vkGetDisplayPlaneCapabilitiesKHR(gpu, displayMode, planeIndex, &planeCaps);

    VkDisplayPlaneAlphaFlagBitsKHR alphaMode = VK_DISPLAY_PLANE_ALPHA_OPAQUE_BIT_KHR;
    if (planeCaps.supportedAlpha & VK_DISPLAY_PLANE_ALPHA_OPAQUE_BIT_KHR) {
        alphaMode = VK_DISPLAY_PLANE_ALPHA_OPAQUE_BIT_KHR;
    } else if (planeCaps.supportedAlpha & VK_DISPLAY_PLANE_ALPHA_GLOBAL_BIT_KHR) {
        alphaMode = VK_DISPLAY_PLANE_ALPHA_GLOBAL_BIT_KHR;
    } else if (planeCaps.supportedAlpha & VK_DISPLAY_PLANE_ALPHA_PER_PIXEL_BIT_KHR) {
        alphaMode = VK_DISPLAY_PLANE_ALPHA_PER_PIXEL_BIT_KHR;
    } else if (planeCaps.supportedAlpha & VK_DISPLAY_PLANE_ALPHA_PER_PIXEL_PREMULTIPLIED_BIT_KHR) {
        alphaMode = VK_DISPLAY_PLANE_ALPHA_PER_PIXEL_PREMULTIPLIED_BIT_KHR;
    }

    VkDisplaySurfaceCreateInfoKHR surfaceInfo = {};
    surfaceInfo.sType = VK_STRUCTURE_TYPE_DISPLAY_SURFACE_CREATE_INFO_KHR;
    surfaceInfo.displayMode = displayMode;
    surfaceInfo.planeIndex = planeIndex;
    surfaceInfo.planeStackIndex = planeStackIndex;
    surfaceInfo.transform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
    surfaceInfo.globalAlpha = 1.0f;
    surfaceInfo.alphaMode = alphaMode;
    surfaceInfo.imageExtent = { _surface_size_x, _surface_size_y };

    VkResult result = vkCreateDisplayPlaneSurfaceKHR(instance, &surfaceInfo, nullptr, &_surface);
    if (result != VK_SUCCESS) {
        fprintf(stderr, "VK_KHR_display: vkCreateDisplayPlaneSurfaceKHR failed (%d)\n", result);
        assert(0 && "Failed to create display plane surface");
        return;
    }

    fprintf(stderr, "VK_KHR_display: surface created successfully\n");
}
