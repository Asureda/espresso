// This file is part of the ESPResSo distribution (http://www.espresso.mpg.de).
// It is therefore subject to the ESPResSo license agreement which you accepted upon receiving the distribution
// and by which you are legally bound while utilizing this file in any form or way.
// There is NO WARRANTY, not even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
// You should have received a copy of that license along with this program;
// if not, refer to http://www.espresso.mpg.de/license.html where its current version can be found, or
// write to Max-Planck-Institute for Polymer Research, Theory Group, PO Box 3148, 55021 Mainz, Germany.
// Copyright (c) 2002-2004; all rights reserved unless otherwise stated.
#ifndef MODES_H
#define MODES_H

/** \file modes.h

    PLEASE INSERT DESCRIPTION

    <b>Responsible:</b>
    <a href="mailto:cooke@mpip-mainz.mpg.de">Ira Cooke</a>
*/

#include "statistics.h"
#include "parser.h"
#include "debug.h"
#include "utils.h"
//#include <fftw.h>
#include <rfftw.h>

/** The full 3d grid for mode analysis */
extern int mode_grid_3d[3];
/** Integer labels for grid axes compared to real axes*/
extern int xdir;
extern int ydir;
extern int zdir;

/** Enumerated constant indicating a Lipid in the top leaflet*/
#define LIPID_UP 0
/** Enumerated constant indicating a Lipid in the bottom leaflet*/
#define LIPID_DOWN 1
/** Enumerated constant indicating a Lipid that has left the bilayer
    but may have become incorporated into a periodic image bilayer */
#define LIPID_STRAY 2
/** Enumerated constant indicating a Lipid that has left the bilayer
    and truly floating in space */
#define REAL_LIPID_STRAY 3
/** The atom type corresponding to a lipid head group */
#define LIPID_HEAD_TYPE 0

/** Flag to indicate when the mode_grid is changed */
extern int mode_grid_changed;

/** Parameter indicating distance beyond which a lipid is said to have
    left the membrane the default value is set in \ref modes.c */
extern double stray_cut_off;

/* Exported Functions */
int modes2d(fftw_complex* result);
void map_to_2dgrid();
/** 
    This routine performs a simple check to see whether a lipid is
    oriented up or down or if it has escaped the bilayer.  In order
    for this routine to work it is essential that the lipids head
    groups are of atom type LIPID_HEAD_TYPE

    \param id The particle identifier
    \param partCfg An array of sorted particles
    \param zref The average z position of all particles


 */
int lipid_orientation( int id, Particle* partCfg , double zref, double director[3]);

/**
   This routine calculates the orientational order parameter for a
   lipid bilayer as defined in Brannigan and Brown 2004. 
*/
int orient_order(double* result);

#endif


