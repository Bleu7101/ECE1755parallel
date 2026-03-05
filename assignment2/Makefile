INCLUDEPATH = Murphi3.1/include
MURPHI = Murphi3.1/bin/mu.x86_64_prebuilt
CXX = g++ -DCATCH_DIV
CFLAGS = -Wno-write-strings -m32
OFLAGS = -O3

SAMPLE_DIR = Murphi3.1/ece1755_sample

%: %.C
	${CXX} ${CFLAGS} ${OFLAGS} -o $@ $@.C -I${INCLUDEPATH} -lm

%.C: %.m
	${MURPHI} $<

# Copy the sample twostate model to the outer folder.
twostate.m: ${SAMPLE_DIR}/twostate.m
	cp $< $@

# Refresh twostate artifacts from the sample and build locally.
.PHONY: twostate_sample
twostate_sample: twostate.m
	rm -f twostate.C twostate
	${MAKE} twostate

twostate: twostate.C
	${CXX} ${CFLAGS} ${OFLAGS} -o $@ $@.C -I${INCLUDEPATH} -lm

.PHONY: clean
clean:
	rm -f protocol protocol.C protocol_opt protocol_opt.C twostate twostate.C
