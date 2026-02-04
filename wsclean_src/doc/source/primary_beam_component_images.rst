Primary beam (component) images
===============================

Depending on the image mode, WSClean may output one Stokes I beam image, or up to 16 beam component images:

- In gridding correction mode (using :doc:`faceting <facet_based_imaging>` or :doc:`IDG <image_domain_gridding>`, a single Stokes I beam response image is produced.
- In image-based correction (using ``-apply-primary-beam``), WSClean makes up to 16 beam component images that together form a Mueller matrix.

Both primary beam modes will be described in the next two sections.

Single Stokes I response image
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

WSClean will produce a single Stokes I response image in facet-based imaging and when using IDG. This response image is a combination of the average response of the primary beam and the average applied solution gains. For understanding the beam image in facet mode, see :doc:`facet-based imaging <facet_based_imaging>`.

Mueller-matrix component images
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
As described in the :doc:`primary beam correction chapter <primary_beam_correction>`, in image-based primary-beam correcting mode, WSClean will store 16 separate images (e.g. named ``wsclean-beam-0.fits``, ``wsclean-beam-1.fits``, ..., ``wsclean-beam-15.fits``), where each is one Mueller-matrix component.

The images are somewhat difficult to interpret, because the response pattern that any one of these individual images shows might not reflect the shape of the beam. 

Mueller matrix structure
------------------------
The images form the lower triangle of the Hermitian matrix. For the diagonal elements, only the real value is stored, and off-diagonal elements contain two images: the real and imaginary parts. They're counted from left to right, top to bottom, so their indices correspond to the following positions::
  
  [0]
  [1]+[ 2]i   [ 3]
  [4]+[ 5]i   [ 6]+[ 7]i   [ 8]
  [9]+[10]i   [11]+[12]i   [13]+[14]i   [15]

This implies for example that the diagonal elements are stored in images named like ``wsclean-beam-0.fits``, ``wsclean-beam-3.fits``, ``wsclean-beam-8.fits``, ``wsclean-beam-15.fits``, and the bottom-left entry of the matrix is split into a real part (``wsclean-beam-9.fits``) and an imaginary part (``wsclean-beam-10.fits``).

Interpreting the images
-----------------------
To turn a Mueller matrix into something that can be interpreted / validated, one option is to use the 16 images to form the Mueller matrix for each pixel (see below) and multiply this with the vector ``(0.5; 0.0; 0.0; 0.5)``. This results in the full Jones sensitivity of the beam. Starting :doc:`WSClean 3.2 <changelogs/v3.2>`, only the components of the Mueller matrix that are necessary for the correction are stored, e.g. with Stokes I imaging, only element 0 and 15 are stored. 
