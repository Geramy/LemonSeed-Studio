# Builds the GPU kernels into code objects for gfx1201.
TARGET  ?= gfx1201
CLANG   ?= clang
LLD     ?= ld.lld
BUILD   := build/$(TARGET)

KERNELS := $(wildcard kernels/*.cl)
OBJECTS := $(patsubst kernels/%.cl,$(BUILD)/%.hsaco,$(KERNELS))

CFLAGS  := -target amdgcn-amd-amdhsa -mcpu=$(TARGET) -O3 -nogpulib -cl-std=CL2.0

.PHONY: all clean disasm

all: $(OBJECTS)

$(BUILD)/%.o: kernels/%.cl | $(BUILD)
	$(CLANG) $(CFLAGS) -c $< -o $@

$(BUILD)/%.hsaco: $(BUILD)/%.o
	$(LLD) -shared $< -o $@
	@echo "linked $@"

$(BUILD):
	mkdir -p $@

disasm: $(OBJECTS)
	@for object in $^; do llvm-objdump -d --mcpu=$(TARGET) $$object; done

clean:
	rm -rf build
