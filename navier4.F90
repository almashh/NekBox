!-----------------------------------------------------------------------
!> \file navier4.F90
!! \brief Module for projecting out solutions before Helmholtz solves 
!! \date January 2015
!! \author Max Hutchinson
!! \author Paul Fischer
!!
!! This module provides hsolve, a Helmholtz (or Poisson) solver that
!! additionally takes an approximation space and projects out the 
!! portion of the residual that resides in that space.  The projectors
!! are generally taken to be past solutions to the same Helmholtz
!! problem, and the oldest solution is replaced with the current solution
!! at the end of hsolve.
!-----------------------------------------------------------------------
module helmholtz
  use kinds, only : DP
  implicit none


  public :: hsolve, approx_space, init_approx_space
  private :: projh, gensh, hconj, updrhsh, hmhzpf

  !> Type to hold the approximation space.
  !! Should not be modified outside this module, so more of a handle
  type approx_space
    real(DP), allocatable :: projectors(:,:) !>!< past solutions that span approx. space
    integer :: n_max !>!< Maximum number of projectors
    integer :: n_sav !>!< Actual number of projectors
    integer :: next !>!< Next projector slot to fill in  
    real(DP) :: dt !>!< dt used in building H

    !> Reduced rep of the matrix operator in the approximation space
    real(DP), allocatable :: H_red(:,:) 
  end type approx_space

contains

!> \brief Initialize approximation space object
!!
!! Simple assigns and allocations
subroutine init_approx_space(apx, n_max, ntot)
  use kinds, only : DP
  implicit none
  type(approx_space), intent(out) :: apx
  integer, intent(in) :: n_max, ntot
  apx%n_max = n_max
  apx%n_sav = 0
  apx%next  = 0
  allocate(apx%projectors(ntot, 0:n_max), apx%H_red(n_max, n_max))
  apx%projectors = 0._dp
  apx%H_red      = 0._dp
  apx%dt         = 0._dp
end subroutine init_approx_space

!> \brief Project out the part of the residual in the approx space.
!!
!! Starts by finding the EVD H_red to get orthogonal projectors.
!! Then, computes the overlap of the residual with each projector
!! and mixes them based on the EVD to get an orthogonal projection.
!! Next, multiplies by 1/\lambda to take the inverse and expands
!! back into the full space to populate the approximate solution: projectors(:,0) 
subroutine projh(r,h1,h2,bi,vml,vmk, apx, wl,ws,name4)
  use kinds, only : DP, QP
  use size_m, only : nx1, ny1, nz1, nelv, nid
  use geom, only : voltm1, volvm1
  use tstep, only : istep, ifield, nelfld
  use parallel, only : nid
  use ctimer, only : nproj, tproj, proj_flop, proj_mop
  use ds, only : dssum
  use ctimer, only : dnekclock
  implicit none

  real(DP), intent(inout) :: r(*)   !>!< residual
  real(DP), intent(in)    :: h1(*)  !>!< coefficient of A (stiffness)
  real(DP), intent(in)    :: h2(*)  !>!< coefficient of M (mass)
  real(DP), intent(in)    :: vml(*) !>!< multiplicity array
  real(DP), intent(in)    :: vmk(*) !>!< mask array
  real(DP), intent(in)    :: bi(*)  !>!< inverse mass matrix
  real(DP), intent(out)   :: wl(*)  !>!< large work array (size lx1*ly1*lz1*nelv)
  real(DP), intent(out)   :: ws(*)  !>!< small work array (size 2*max vecs)
  type(approx_space), intent(inout) :: apx !>!< Current approx space
  character(4), intent(in) :: name4 !>!< Name of field for debug printing

  integer :: nel, ntot, i, j, n10
  real(DP) :: vol, alpha1, alpha2, ratio
  real(DP), external :: glsc23
  real(DP), allocatable :: evecs(:,:), ev(:)
  integer :: ierr
  real(DP), parameter :: one = 1._dp, zero = 0._dp
  real(DP) :: etime
  real(QP) :: qsum 

  nproj = nproj + 1
  etime = dnekclock() 

  if (apx%n_sav == 0) then
    apx%projectors(:,0) = 0._dp
    return
  endif

  nel  = nelfld(ifield)
  ntot = nx1*ny1*nz1*nel

  vol = voltm1
  if (nel == nelv) vol = volvm1

  ! Diag to see how much reduction in the residual is attained.
  proj_flop = proj_flop + 3*ntot-1
  proj_mop  = proj_mop + 3*ntot
  alpha1 = glsc23(r,bi,vml,ntot)
  if (alpha1 > 0) alpha1 = sqrt(alpha1/vol)

  ! Update approximation space if dt has changed
  etime = etime - dnekclock()
  call updrhsh(apx,h1,h2,vml,vmk,ws)
  etime = etime + dnekclock()

  !...............................................................
  ! Orthogonalize the approximation space
  !> \note This dsyev call and the following dgemv 
  !> are task-parallel!
  if (3 * apx%n_sav -1 > ntot) &
    write(*,*) "wl isn't big enough to be dsyev's work"

  allocate(evecs(apx%n_sav, apx%n_sav), ev(apx%n_sav))
  evecs = apx%H_red(1:apx%n_sav,1:apx%n_sav)
  call dsyev('V', 'U', apx%n_sav, &
             evecs, apx%n_sav, &
             ev, &
             wl, ntot, ierr) 
  if (nid == 0 .and. ierr /= 0) write(*,*) "DSYEV failed", ierr

  ! Compute overlap of residual and (non-orthogonal) projectors
  ! \note wl written then read
  proj_flop = proj_flop + ntot
  proj_mop  = proj_mop + 3*ntot
  wl(1:ntot) = r(1:ntot) * vml(1:ntot)

  proj_flop = proj_flop + (2*ntot-1)*apx%n_sav
  proj_mop  = proj_mop + apx%n_sav * (ntot+1)
  call dgemv('T', ntot, apx%n_sav, &
             one,  apx%projectors(:,1:apx%n_sav), ntot, &
                   wl, 1, &
             zero, ws, 1)
  call gop(ws, ws(1+apx%n_sav), '+  ', apx%n_sav)

  !...............................................................
  ! Mix the overlaps to get the orthogonal projection
  ! and take the inverse by dividing by \lambda 
  ! \todo sort the sums for more precision
  do i = 1, apx%n_sav
    qsum = 0._qp
    do j = 1, apx%n_sav
      qsum = qsum + evecs(j,i) * ws(j)
    enddo 
  enddo
  do i = 1, apx%n_sav
    qsum = 0._qp
    do j = 1, apx%n_sav
      qsum = qsum + evecs(j,i) * ws(j)
    enddo
    ev(i) = qsum / ev(i)
  enddo

  ! Compute the weights for the approximate solution
  do i = 1, apx%n_sav
    qsum = 0._qp
    do j = 1, apx%n_sav
      qsum = qsum + evecs(i,j) * ev(j)
    enddo
    ws(i) = qsum
  enddo

  ! Expand the approximate solution wrt (non-orth.) projectors
  proj_flop = proj_flop + ntot*(2*apx%n_sav-1)
  proj_mop  = proj_mop + (apx%n_sav+1) * ntot
  call dgemv('N', ntot, apx%n_sav, &
             one,  apx%projectors(:,1:apx%n_sav), ntot, &
                   ws, 1, &
             zero, apx%projectors(:,0), 1)

  !...............................................................
  ! Compute the new residual explicitly
  ! This fixes any numerical precision issues in previous sections
  etime = etime - dnekclock()
  call axhelm  (wl,apx%projectors(:,0),h1,h2,1,1)
  etime = etime + dnekclock()

  proj_flop = proj_flop + ntot
  proj_mop  = proj_mop + 2*ntot 
  wl(1:ntot) = wl(1:ntot) * vmk(1:ntot)

  call dssum   (wl)

  proj_flop = proj_flop + ntot
  proj_mop  = proj_mop + 2*ntot 
  r(1:ntot) = r(1:ntot) - wl(1:ntot)

  !...............................................................
  ! Recompute the norm of the residual to show how much its shrunk
  proj_flop = proj_flop + 3*ntot-1
  proj_mop  = proj_mop + 3*ntot
  alpha2 = glsc23(r,bi,vml,ntot)

  if (alpha2 > 0) alpha2 = sqrt(alpha2/vol)
  ratio  = alpha1/alpha2

  tproj = tproj + (dnekclock() - etime)
  n10=min(10,apx%n_sav)

  if (nid == 0) write(6,10) istep,name4,alpha1,alpha2,ratio,apx%n_sav
  10 format(4X,I7,4x,a4,' alph1n',1p3e12.4,i6)

  if (nid == 0) write(6,11) istep,name4,apx%n_sav,(ev(i),i=1,n10)
  11 format(4X,I7,4x,a4,' halpha',i6,10(1p10e12.4,/,17x))

  return
end subroutine projh

!-----------------------------------------------------------------------
!> \brief Reconstruct the solution to the original problem by adding back
!!     the approximate solution, add solution to approximation space.
subroutine gensh(v1,h1,h2,vml,vmk,apx,ws)
  use kinds, only : DP
  use mesh, only : niterhm
  use ctimer, only : othr_flop, othr_mop
  implicit none

  REAL(DP), intent(inout) :: V1 (*) !>!< Full solution
  REAL(DP), intent(in)    :: H1 (*) !>!< coefficient of A (stiffness)
  REAL(DP), intent(in)    :: H2 (*) !>!< coefficient of M (mass)
  REAL(DP), intent(in)    :: vmk(*) !>!< multiplicity array
  REAL(DP), intent(in)    :: vml(*) !>!< mask array
  real(DP), intent(out)   :: ws(:)  !>!< small workspace to pass-through
  type(approx_space), intent(inout) :: apx !>!< current approximation space

  integer :: ntot
  ntot = size(apx%projectors,1)
  othr_mop = othr_mop + 5*ntot
  othr_flop = othr_flop + ntot

  ! Reconstruct solution 
  v1(1:ntot) = v1(1:ntot) + apx%projectors(:,0)

  ! If the new vector is in the space already, don't re-add it.
  if (niterhm < 1) return      

  ! Add the solution to the approximation space
  apx%n_sav = min(apx%n_sav + 1, apx%n_max)
  apx%next  = mod(apx%next, apx%n_max) + 1
  apx%projectors(:,apx%next) = v1(1:ntot)

  ! Update the approximation space
  call hconj(apx,apx%next,h1,h2,vml,vmk,ws)

  return
end subroutine gensh

!-----------------------------------------------------------------------
!> \brief Update the k-th row/column of H_red 
subroutine hconj(apx,k,h1,h2,vml,vmk,ws)
  use kinds,  only : DP
  use ctimer, only : nhconj, thconj, hconj_flop, hconj_mop, dnekclock
  use ds, only : dssum
  implicit none

  type(approx_space), intent(inout) :: apx !>!< Current approximation space
  integer,  intent(in) :: k      !>!< Index of new projector
  real(DP), intent(in) :: h1(*)  !>!< coefficient of A (stiffness)
  real(DP), intent(in) :: h2(*)  !>!< coefficient of M (mass)
  real(DP), intent(in) :: vml(*) !>!< multiplicity array
  real(DP), intent(in) :: vmk(*) !>!< mask array
  real(DP), intent(out) :: ws(*) !>!< small workspace

  integer :: i, ntot
  real(DP), parameter :: one = 1._dp, zero = 0._dp
  real(DP) :: etime

  ntot= size(apx%projectors, 1)
  nhconj = nhconj + 1

  ! Compute H| projectors(:,k) >
  call axhelm  (apx%projectors(:,0),apx%projectors(:,k),h1,h2,1,1)

  etime = dnekclock()

  hconj_flop = hconj_flop + ntot
  hconj_mop  = hconj_flop + 3*ntot
  apx%projectors(:,0) = apx%projectors(:,0) * vmk(1:ntot)
  call dssum   (apx%projectors(:,0))

  hconj_flop = hconj_flop + ntot
  hconj_mop  = hconj_flop + 3*ntot
  apx%projectors(:,0) = apx%projectors(:,0) * vml(1:ntot)

  ! Compute < projectors(:,i) | H | projectors(:,k) > for i \in [1,n_sav]
  hconj_flop = hconj_flop + apx%n_sav*(2*ntot-1)
  hconj_mop  = hconj_mop + apx%n_sav * (ntot +1)
  call dgemv('T', ntot, apx%n_sav, &
             one,  apx%projectors(1,1), ntot, &
                   apx%projectors(1,0), 1, &
             zero, apx%H_red(1,k), 1)
  call gop(apx%H_red(:,k), ws, '+  ', apx%n_sav)

  ! Re-symmetrize
  do i = 1, apx%n_sav
    apx%H_red(k,i) = apx%H_red(i,k)
  enddo
  thconj = thconj + (dnekclock() - etime)

  return
end subroutine hconj

!-----------------------------------------------------------------------
!> \brief Recompute H_red if dt has changed
subroutine updrhsh(apx,h1,h2,vml,vmk,ws)
  use kinds, only : DP
  use input, only : ifvarp, iflomach
  use tstep, only : dt, ifield
  implicit none

  type(approx_space), intent(inout) :: apx !>!< current approximation space
  real(DP), intent(in) :: h1(*)  !>!< coefficient of A (stiffness)
  real(DP), intent(in) :: h2(*)  !>!< coefficient of M (mass)
  real(DP), intent(in) :: vml(*) !>!< multiplicity array
  real(DP), intent(in) :: vmk(*) !>!< mask array
  real(DP), intent(out) :: ws(*) !>!< small workspace

  logical :: ifupdate
  logical, save :: ifnewdt = .false.
  integer :: n_sav, k

  ! First, we have to decide if the dt has changed.
  ifupdate = .FALSE. 
  if (abs(dt-apx%dt) > 1.e-9) then
      apx%dt   = dt
      ifnewdt  = .TRUE. 
      ifupdate = .TRUE. 
  elseif (ifnewdt) then
      ifnewdt = .FALSE. 
  endif
  if (ifvarp(ifield)) ifupdate = .TRUE. 
  if (iflomach)       ifupdate = .TRUE. 

  ! If it has, recompute apx%H_red column by column
  if (ifupdate) then  
    n_sav = apx%n_sav 
    ! Loops over columns to update
    do k=1,n_sav
      apx%n_sav = k 
      call hconj(apx, apx%n_sav, h1,h2,vml,vmk,ws)
    enddo
  endif

  return
end subroutine updrhsh

!-----------------------------------------------------------------------
subroutine hmhzpf(name,u,r,h1,h2,mask,mult,imesh,tli,maxit,isd,bi)
  use kinds, only : DP
  use size_m, only : lx1, ly1, lz1
  use size_m, only : nx1, ny1, nz1, nelv, nelt, ndim
  use ctimer, only : etime1, dnekclock, thmhz
  use fdmh1, only : kfldfdm
  use input, only : param
  implicit none

  CHARACTER(4) ::    NAME
  REAL(DP), intent(out) :: U    (LX1,LY1,LZ1,1) !>!< solution vector
  REAL(DP), intent(in)  :: R    (LX1,LY1,LZ1,1) !>!< right hand side
  REAL(DP), intent(in)  :: H1   (LX1,LY1,LZ1,1) !>!< coefficient of A (stiffness)
  REAL(DP), intent(in)  :: H2   (LX1,LY1,LZ1,1) !>!< coefficient of M (mass)
  REAL(DP), intent(in)  :: MASK (LX1,LY1,LZ1,1) !>!< mask array
  REAL(DP), intent(in)  :: MULT (LX1,LY1,LZ1,1) !>!< multiplicity array
  REAL(DP), intent(in)  :: bi   (LX1,LY1,LZ1,1) !>!< inverse of mass matrix
  real(DP) :: tli
  integer :: imesh, maxit, isd

  integer :: ntot
  real(DP) :: tol

  etime1=dnekclock()

  IF (IMESH == 1) NTOT = NX1*NY1*NZ1*NELV
  IF (IMESH == 2) NTOT = NX1*NY1*NZ1*NELT

  tol = tli
  if (param(22) /= 0) tol = abs(param(22))
  CALL CHKTCG1 (TOL,R,H1,H2,MASK,MULT,IMESH,ISD)


!   Set flags for overlapping Schwarz preconditioner (pff 11/12/98)

  kfldfdm = -1
!   if (name.eq.'TEMP') kfldfdm =  0
!   if (name.eq.'VELX') kfldfdm =  1
!   if (name.eq.'VELY') kfldfdm =  2
!   if (name.eq.'VELZ') kfldfdm =  3
  if (name == 'PRES') kfldfdm =  ndim+1

  call cggo &
  (u,r,h1,h2,mask,mult,imesh,tol,maxit,isd,bi,name)
  thmhz=thmhz+(dnekclock()-etime1)


  return
end subroutine hmhzpf

!-----------------------------------------------------------------------
!> \brief Either std. Helmholtz solve, or a projection + Helmholtz solve
subroutine hsolve(name,u,r,h1,h2,vmk,vml,imsh,tol,maxit,isd &
    ,apx,bi)
  use kinds, only : DP
  use size_m, only : lx1, ly1, lz1, lelv
  use input, only : param
  use string, only : capit
  use tstep, only : ifield, nelfld, istep
  use ctimer, only : dnekclock, nhslv, thslv
  use ctimer, only : othr_mop, othr_flop
  use ds, only : dssum
  implicit none

  CHARACTER(4), intent(in) :: NAME !>!< name of field we're solving for
  REAL(DP), intent(out)   :: U    (LX1,LY1,LZ1,lelv) !>!< solution vector
  REAL(DP), intent(inout) :: R    (LX1,LY1,LZ1,lelv) !>!< right hand side
  REAL(DP), intent(in)    :: H1   (LX1,LY1,LZ1,lelv) !>!< coefficient of A (stiffness)
  REAL(DP), intent(in)    :: H2   (LX1,LY1,LZ1,lelv) !>!< coefficient of M (mass)
  REAL(DP), intent(in)    :: vmk  (LX1,LY1,LZ1,lelv) !>!< mask array
  REAL(DP), intent(in)    :: vml  (LX1,LY1,LZ1,lelv) !>!< multiplicity array
  integer,  intent(in)    :: imsh                 !>!< imesh?
  real(DP), intent(in)    :: tol                  !>!< residual tolerance
  integer,  intent(in)    :: maxit                !>!< maximum number of iterations
  integer,  intent(in)    :: isd                  !>!< something to do with axi-symmetric
  type(approx_space), intent(inout) :: apx !>!< current approximation space
  REAL(DP), intent(in)    :: bi   (LX1,LY1,LZ1,*) !>!< inverse of mass matrix

  real(DP), allocatable :: w1(:)
  real(DP), allocatable :: w2(:)

  logical :: ifstdh
  character(4) ::  cname
  integer :: nel
  real(DP) :: rinit
  real(DP), external :: glsc23
  real(DP) :: etime

  nhslv = nhslv + 1
  etime = dnekclock()


  call chcopy(cname,name,4)
  call capit (cname,4)

  ! figure out if we're projecting or not
  ifstdh = .TRUE. 
  ! Is this a pressure solve?
  if (cname == 'PRES') then
    if (param(95) /= 0 .AND. istep > param(95) .and. param(93) > 0) then
      ifstdh = .FALSE.
    endif
  ! Is this a velocity solve?
  else
    if (param(94) /= 0 .AND. istep > param(94) .and. param(92) > 0) then
      ifstdh = .FALSE. 
    endif
  endif


  if (ifstdh) then
    etime = etime - dnekclock()
    call hmholtz(name,u,r,h1,h2,vmk,vml,imsh,tol,maxit,isd)
    etime = etime + dnekclock()

  else

      nel = nelfld(ifield)

      othr_mop = othr_mop + 3*lx1*ly1*lz1*nel
      othr_flop = othr_flop + lx1*ly1*lz1*nel
      call dssum  (r(:,1,1,1))
      r(:,:,:,1:nel) = r(:,:,:,1:nel) * vmk(:,:,:,1:nel)

      allocate(w2(2+2*apx%n_max))
      allocate(w1(lx1*ly1*lz1*lelv))
      etime = etime - dnekclock()
      call projh  (r,h1,h2,bi,vml,vmk,apx,w1,w2,name)
      deallocate(w1)

      call hmhzpf (name,u,r,h1,h2,vmk,vml,imsh,tol,maxit,isd,bi)
      call gensh  (u,h1,h2,vml,vmk,apx,w2)
      etime = etime + dnekclock()

  endif

  thslv = thslv + (dnekclock() - etime)

  return
end subroutine hsolve
!-----------------------------------------------------------------------

end module helmholtz
