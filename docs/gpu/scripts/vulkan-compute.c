/* Dispatch a compute shader on the first Vulkan device and read back what it wrote. */
#include <stdio.h>
#include <stdlib.h>
#include <vulkan/vulkan.h>

#define N 1024u
#define CHECK(call) do { VkResult r = (call); if (r != VK_SUCCESS) { \
    printf("%s -> %d\ncompute=failed\n", #call, r); return 1; } } while (0)

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: %s <spv>\n", argv[0]); return 2; }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 2; }
    static uint32_t code[4096];
    size_t spv = fread(code, 1, sizeof code, f);
    fclose(f);

    VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_1};
    VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
    VkInstance inst;
    CHECK(vkCreateInstance(&ici, NULL, &inst));

    uint32_t count = 1;
    VkPhysicalDevice pd;
    VkResult er = vkEnumeratePhysicalDevices(inst, &count, &pd);
    if ((er != VK_SUCCESS && er != VK_INCOMPLETE) || count == 0) { printf("no device\ncompute=failed\n"); return 1; }
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(pd, &props);
    printf("device=%s\n", props.deviceName);

    float prio = 1.0f;
    uint32_t family = 0, families = 16;
    VkQueueFamilyProperties qf[16];
    vkGetPhysicalDeviceQueueFamilyProperties(pd, &families, qf);
    while (family < families && !(qf[family].queueFlags & VK_QUEUE_COMPUTE_BIT)) family++;
    if (family == families) { printf("no compute queue\ncompute=failed\n"); return 1; }
    VkDeviceQueueCreateInfo qci = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = family, .queueCount = 1, .pQueuePriorities = &prio};
    VkDeviceCreateInfo dci = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci};
    VkDevice dev;
    CHECK(vkCreateDevice(pd, &dci, NULL, &dev));
    VkQueue queue;
    vkGetDeviceQueue(dev, family, 0, &queue);

    VkBufferCreateInfo bci = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = N * sizeof(uint32_t),
        .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT};
    VkBuffer buf;
    CHECK(vkCreateBuffer(dev, &bci, NULL, &buf));
    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(dev, buf, &req);
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(pd, &mp);
    VkMemoryPropertyFlags want = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    uint32_t type = 0;
    while (type < mp.memoryTypeCount && !((req.memoryTypeBits >> type & 1) && (mp.memoryTypes[type].propertyFlags & want) == want)) type++;
    if (type == mp.memoryTypeCount) { printf("no host-visible memory\ncompute=failed\n"); return 1; }
    VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size, .memoryTypeIndex = type};
    VkDeviceMemory mem;
    CHECK(vkAllocateMemory(dev, &mai, NULL, &mem));
    CHECK(vkBindBufferMemory(dev, buf, mem, 0));

    VkShaderModuleCreateInfo smci = {.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = spv, .pCode = code};
    VkShaderModule sm;
    CHECK(vkCreateShaderModule(dev, &smci, NULL, &sm));
    VkDescriptorSetLayoutBinding bind = {.descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT};
    VkDescriptorSetLayoutCreateInfo dslci = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 1, .pBindings = &bind};
    VkDescriptorSetLayout dsl;
    CHECK(vkCreateDescriptorSetLayout(dev, &dslci, NULL, &dsl));
    VkPipelineLayoutCreateInfo plci = {.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1, .pSetLayouts = &dsl};
    VkPipelineLayout layout;
    CHECK(vkCreatePipelineLayout(dev, &plci, NULL, &layout));
    VkComputePipelineCreateInfo cpci = {.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO, .layout = layout,
        .stage = {.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_COMPUTE_BIT, .module = sm, .pName = "main"}};
    VkPipeline pipe;
    CHECK(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &cpci, NULL, &pipe));

    VkDescriptorPoolSize size = {.type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1};
    VkDescriptorPoolCreateInfo dpci = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &size};
    VkDescriptorPool pool;
    CHECK(vkCreateDescriptorPool(dev, &dpci, NULL, &pool));
    VkDescriptorSetAllocateInfo dsai = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = pool, .descriptorSetCount = 1, .pSetLayouts = &dsl};
    VkDescriptorSet set;
    CHECK(vkAllocateDescriptorSets(dev, &dsai, &set));
    VkDescriptorBufferInfo dbi = {.buffer = buf, .range = VK_WHOLE_SIZE};
    VkWriteDescriptorSet write = {.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = set, .descriptorCount = 1,
        .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &dbi};
    vkUpdateDescriptorSets(dev, 1, &write, 0, NULL);

    VkCommandPoolCreateInfo cpi = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = family};
    VkCommandPool cp;
    CHECK(vkCreateCommandPool(dev, &cpi, NULL, &cp));
    VkCommandBufferAllocateInfo cbai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = cp, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
    VkCommandBuffer cb;
    CHECK(vkAllocateCommandBuffers(dev, &cbai, &cb));
    VkCommandBufferBeginInfo begin = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    CHECK(vkBeginCommandBuffer(cb, &begin));
    vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
    vkCmdBindDescriptorSets(cb, VK_PIPELINE_BIND_POINT_COMPUTE, layout, 0, 1, &set, 0, NULL);
    vkCmdDispatch(cb, N / 64, 1, 1);
    /* Make the shader's writes visible to the host before the read below. */
    VkMemoryBarrier barrier = {.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT, .dstAccessMask = VK_ACCESS_HOST_READ_BIT};
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &barrier, 0, NULL, 0, NULL);
    CHECK(vkEndCommandBuffer(cb));
    VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb};
    CHECK(vkQueueSubmit(queue, 1, &si, VK_NULL_HANDLE));
    CHECK(vkQueueWaitIdle(queue));

    uint32_t *out;
    CHECK(vkMapMemory(dev, mem, 0, VK_WHOLE_SIZE, 0, (void **)&out));
    uint32_t wrong = 0;
    for (uint32_t i = 0; i < N; i++) if (out[i] != i * 3u + 7u) wrong++;
    printf("values_checked=%u\nvalues_wrong=%u\n", N, wrong);
    printf("compute=%s\n", wrong ? "failed" : "ok");
    return wrong ? 1 : 0;
}
