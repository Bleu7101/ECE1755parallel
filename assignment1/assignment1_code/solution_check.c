// 3D Ultrasound beamforming solution check for EECS 570 
// Created by: Richard Sampson, Amlan Nayak, Thomas F. Wenisch
// Revision 1.0 - 11/15/16

#include <stdio.h>
#include <stdlib.h>
#include <math.h>

int main (int argc, char **argv) {

	int size = atoi(argv[1]);

	int pts_r = 1560; // Radial points along scanline
	int sls_t = size; // Number of scanlines in theta
	int sls_p = size; // Number of scanlines in phi

	float test_value; // Value from test file
	float true_value; // Correct value
	float diff_value = 0; 

	int it_r; // Iterator for r
	int it_t; // Iterator for theta
	int it_p; // Iterator for phi

	FILE *ftest;
	FILE *ftrue;

	char buff[128];
	#ifdef __MIC__
	  sprintf(buff, "/beamforming_solution_%s.bin", argv[1]);
	#else //!__MIC__
	  sprintf(buff, "/cad2/ece1755s/assignment1_data/beamforming_solution_%s.bin", argv[1]);
	#endif
	ftrue = fopen(buff, "rb");

	#ifdef __MIC__
	  sprintf(buff, "./beamforming_output.bin");
	#else //!__MIC__
	  sprintf(buff, "./beamforming_output.bin");
	#endif
	ftest = fopen(buff, "rb");

	for (it_t = 0; it_t < sls_t; it_t++) {
		for (it_p = 0; it_p < sls_p; it_p++) {
			for (it_r = 0; it_r < pts_r; it_r++) {
				fread(&test_value, sizeof(float), 1, ftest);
				fread(&true_value, sizeof(float), 1, ftrue);
				diff_value += (test_value - true_value) * (test_value - true_value);
			}
		}
	}
	diff_value = (float)sqrt(diff_value/sls_t/sls_p/it_r);
	printf("RMS: %e\n", diff_value);


	fclose(ftest);
	fclose(ftrue);

	return 0;
}
