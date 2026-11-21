dumpvars:
	@echo "$(SOURCES_CXX)" | tr ' ' '\n' | grep . > $(OUT)/cxx.txt || true
	@echo "$(SOURCES_C)" | tr ' ' '\n' | grep . > $(OUT)/c.txt || true
	@echo "$(CXXFLAGS) $(INCFLAGS)" > $(OUT)/cxxflags.txt
	@echo "$(CFLAGS) $(INCFLAGS) $(FLAGS)" > $(OUT)/cflags.txt
	@echo "$(FLAGS)" > $(OUT)/flags.txt

# ScummVM's libretro makefile lists object files and per-module libraries, not sources; objs_to_sources.sh maps them back.
dumpobjs:
	@echo "$(DETECT_OBJS) $(OBJS) $(OBJS_DEPS) $(foreach M,$(MODULES),$(MODULE_OBJS-$(M)))" | tr ' ' '\n' | grep . | grep -v '\.a$$' | sort -u > $(OUT)/objs.txt
	@echo "$(DEFINES) $(INCLUDES)" > $(OUT)/defines.txt
	@echo "$(CXXFLAGS)" > $(OUT)/cxxflags.txt
	@echo "$(CFLAGS)" > $(OUT)/cflags.txt
