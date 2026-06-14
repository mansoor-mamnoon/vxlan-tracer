package diag

import "testing"

func TestCheckMTU(t *testing.T) {
	cases := []struct {
		name        string
		overlayMTU  int
		underlayMTU int
		wantSafe    int
		wantExcess  int
		wantCorrect bool
	}{
		{
			name:        "correct: overlay 1450, underlay 1500",
			overlayMTU:  1450,
			underlayMTU: 1500,
			wantSafe:    1450,
			wantExcess:  0,
			wantCorrect: true,
		},
		{
			name:        "wrong: overlay 1500 (default), underlay 1500",
			overlayMTU:  1500,
			underlayMTU: 1500,
			wantSafe:    1450,
			wantExcess:  50,
			wantCorrect: false,
		},
		{
			name:        "cloud MTU 9000: overlay 8950, underlay 9000",
			overlayMTU:  8950,
			underlayMTU: 9000,
			wantSafe:    8950,
			wantExcess:  0,
			wantCorrect: true,
		},
		{
			name:        "cloud MTU 9000, overlay still 1500",
			overlayMTU:  1500,
			underlayMTU: 9000,
			wantSafe:    8950,
			wantExcess:  0,
			wantCorrect: true,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := CheckMTU(c.overlayMTU, c.underlayMTU)
			if got.SafeOverlay != c.wantSafe {
				t.Errorf("SafeOverlay: got %d, want %d", got.SafeOverlay, c.wantSafe)
			}
			if got.ExcessBytes != c.wantExcess {
				t.Errorf("ExcessBytes: got %d, want %d", got.ExcessBytes, c.wantExcess)
			}
			if got.Correct != c.wantCorrect {
				t.Errorf("Correct: got %v, want %v", got.Correct, c.wantCorrect)
			}
		})
	}
}

func TestProjectedOuterFrame(t *testing.T) {
	// MSS=1460 → inner IP=1500 → outer frame = 1500+14+50 = 1564
	got := ProjectedOuterFrame(1500)
	if got != 1564 {
		t.Errorf("ProjectedOuterFrame(1500) = %d, want 1564", got)
	}
	// inner IP=1450 → outer frame = 1450+14+50 = 1514
	got = ProjectedOuterFrame(1450)
	if got != 1514 {
		t.Errorf("ProjectedOuterFrame(1450) = %d, want 1514", got)
	}
}

func TestMaxSafeInnerIPLen(t *testing.T) {
	// underlay 1500: max inner IP = 1500 - 14 - 50 = 1436
	got := MaxSafeInnerIPLen(1500)
	if got != 1436 {
		t.Errorf("MaxSafeInnerIPLen(1500) = %d, want 1436", got)
	}
}
