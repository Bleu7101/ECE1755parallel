all: beamform solution_check beamform_mt beamform_mt_512

beamform: beamform.c
	gcc beamform.c -o beamform -lm -O3

solution_check: solution_check.c
	gcc solution_check.c -o solution_check -lm -O3

beamform_mt: beamform_mt.c
	gcc beamform_mt.c -o beamform_mt -lm -O3 -march=native -ffast-math -funroll-loops -lpthread -mavx2 -mfma

beamform_mt_512: beamform_mt_512.c
	gcc beamform_mt_512.c -o beamform_mt_512 -lm -O3 -march=native -ffast-math -funroll-loops -lpthread

clean:
	rm -f beamform solution_check beamform_mt beamform_mt_512 beamforming_output.bin