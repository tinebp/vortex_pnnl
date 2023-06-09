ifneq ($(findstring Makefile, $(MAKEFILE_LIST)), Makefile)
help:
	$(ECHO) "Makefile Usage:"
	$(ECHO) "  make all TARGET=<sw_emu/hw_emu/hw> PLATFORM=<FPGA platform>"
	$(ECHO) "      Command to generate the design for specified Target and Device."
	$(ECHO) ""
	$(ECHO) "  make clean"
	$(ECHO) "      Command to remove the generated non-hardware files."
	$(ECHO) ""
endif

TARGET ?= hw
PLATFORM ?=

PREFIX ?= build

RTL_DIR = ../hdl

BUILD_DIR = $(PREFIX)_$(PLATFORM)_$(TARGET)
BIN_DIR   = $(BUILD_DIR)/bin

RTL_INCLUDE += -I$(RTL_DIR)

CONFIGS += -DSYNTHESIS -DVIVADO

VIVADO = $(XILINX_VIVADO)/bin/vivado

VPP = $(XILINX_VITIS)/bin/v++

CP = cp -rf
RMDIR = rm -rf

ECHO = @echo

XO_CONTAINER = $(BIN_DIR)/krnl_vadd_rtl.xo

XCLBIN_CONTAINER = $(BIN_DIR)/krnl_vadd_rtl.xclbin

EMCONFIG = $(BIN_DIR)/emconfig.json

NCPUS := $(shell grep -c ^processor /proc/cpuinfo)
JOBS := $(shell expr $(NCPUS) - 1)

# Kernel compiler global settings
VPP_FLAGS += --link --target $(TARGET) --platform $(PLATFORM) --save-temps --no_ip_cache
VPP_FLAGS += --vivado.synth.jobs $(JOBS) --vivado.impl.jobs $(JOBS)
VPP_FLAGS += --connectivity.sp krnl_vadd_rtl_1.m_axi_mem:HBM[0:15]
VPP_FLAGS += --report estimate
VPP_FLAGS += --config ../vitis.ini

# Enable perf counters
ifdef PERF
	CONFIGS += -DPERF_ENABLE
endif

# Generates profile summary report
ifdef PROFILE
	VPP_FLAGS += --profile_kernel data:all:all:all
	VPP_FLAGS += --profile_kernel stall:all:all:all
endif

# Debugigng
ifdef DEBUG
	VPP_FLAGS += -g --optimize 0 --debug.protocol all
	ifeq ($(TARGET), hw)
		VPP_FLAGS += --debug.chipscope krnl_vadd_rtl_1
		CONFIGS += -DCHIPSCOPE
	else
		CONFIGS += -DSIMULATION $(DBG_FLAGS)
		VPP_FLAGS += --vivado.prop fileset.sim_1.xsim.elaborate.debug_level=all
	endif
else    
	CONFIGS += -DNDEBUG
	VPP_FLAGS += --optimize 3
endif

# Host
EXECUTABLE = ./test
CMD_ARGS = -x $(XCLBIN_CONTAINER)
CXXFLAGS += -std=c++14 -g -O0 -fmessage-length=0 -I$(XILINX_XRT)/include -I$(XILINX_VIVADO)/include -Wall -I../src
LDFLAGS  += -L$(XILINX_XRT)/lib -pthread -luuid -lxrt_coreutil
HOST_SRCS += ./src/host.cpp ./src/cmdlineparser.cpp ./src/logger.cpp

# RTL Kernel only supports Hardware and Hardware Emulation.
ifneq ($(TARGET),$(findstring $(TARGET), hw hw_emu))
	$(warning WARNING:Application supports only hw hw_emu TARGET. Please use the target for running the application)
endif

.PHONY: all run host clean gen-sources emconfig check-devices

all: check-devices $(XCLBIN_CONTAINER) emconfig host

gen-sources: $(BUILD_DIR)/sources.txt
$(BUILD_DIR)/sources.txt:
	mkdir -p $(BUILD_DIR); cd $(BUILD_DIR); ../scripts/gen_sources.sh $(RTL_INCLUDE) $(CONFIGS) > sources.txt

$(XO_CONTAINER): $(BUILD_DIR)/sources.txt ./kernel.xml
	mkdir -p $(BUILD_DIR); cd $(BUILD_DIR);	$(VIVADO) -mode batch -source ../scripts/gen_xo.tcl -tclargs ../$(XO_CONTAINER) krnl_vadd_rtl sources.txt ../kernel.xml ../$(BUILD_DIR)

$(XCLBIN_CONTAINER): $(XO_CONTAINER)
	mkdir -p $(BIN_DIR); cd $(BUILD_DIR); $(VPP) $(VPP_FLAGS) -o ../$(XCLBIN_CONTAINER) ../$(XO_CONTAINER)

emconfig: $(EMCONFIG)
$(EMCONFIG):
	mkdir -p $(BIN_DIR); cd $(BUILD_DIR); emconfigutil --platform $(PLATFORM) --od ../$(BIN_DIR)

host: $(EXECUTABLE)
$(EXECUTABLE): $(HOST_SRCS)
	g++ $^ $(CXXFLAGS) $(LDFLAGS) -o $@

run: $(EXECUTABLE) $(EMCONFIG)
ifeq ($(TARGET),$(filter $(TARGET),sw_emu hw_emu))
	EMCONFIG_PATH=$(BIN_DIR) XCL_EMULATION_MODE=$(TARGET) $(EXECUTABLE) $(CMD_ARGS)
else
	EMCONFIG_PATH=$(BIN_DIR) $(EXECUTABLE) $(CMD_ARGS)
endif

clean:
	$(RMDIR) $(BUILD_DIR) $(EXECUTABLE)

# Check the devices avaiable
check-devices:
ifndef PLATFORM
	$(error PLATFORM not set. Please set the PLATFORM properly and rerun. Run "make help" for more details.)
endif
ifndef XILINX_VITIS
	$(error XILINX_VITIS variable is not set, please set correctly and rerun)
endif
