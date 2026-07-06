import { useIsLoggedIn, useIsMFAEnabled, useParams } from 'common'
import { useRouter } from 'next/router'
import { PropsWithChildren, useEffect } from 'react'
import { toast } from 'sonner'

import { useOrganizationsQuery } from '@/data/organizations/organizations-query'
import { useProjectDetailQuery } from '@/data/projects/project-detail-query'
import { useDashboardHistory } from '@/hooks/misc/useDashboardHistory'
import { useLastVisitedOrganization } from '@/hooks/misc/useLastVisitedOrganization'
import { useLatest } from '@/hooks/misc/useLatest'
import { useSelectedOrganizationQuery } from '@/hooks/misc/useSelectedOrganization'
import { IS_PLATFORM, SUPERBASE2_ENABLED } from '@/lib/constants'

// Ideally these could all be within a _middleware when we use Next 12
export const RouteValidationWrapper = ({ children }: PropsWithChildren<{}>) => {
  const router = useRouter()
  const { ref, slug, id } = useParams()
  const { data: organization } = useSelectedOrganizationQuery()

  const isLoggedIn = useIsLoggedIn()
  const isUserMFAEnabled = useIsMFAEnabled()

  const { setLastVisitedSnippet, setLastVisitedTable } = useDashboardHistory()
  const { lastVisitedOrganization, setLastVisitedOrganization } = useLastVisitedOrganization()

  // SuperBase² has no `default` project ref — the SB2 API rejects it with 400,
  // which would otherwise cause this wrapper to redirect to /project/default in
  // a loop and toast "You do not have access to this project". Send users to
  // the org-scoped multi-project home instead.
  const DEFAULT_HOME = (IS_PLATFORM || SUPERBASE2_ENABLED)
    ? !!lastVisitedOrganization
      ? `/org/${lastVisitedOrganization}`
      : '/organizations'
    : '/project/default'

  /**
   * Array of urls/routes that should be ignored
   */
  const excemptUrls: string[] = [
    // project creation route, allows the page to self determine it's own route, it will redirect to the first org
    // or prompt the user to create an organaization
    // this is used by database.dev, usually as /new/new-project
    '/new/[slug]',
    '/join',
  ]

  /**
   * Map through all the urls that are excluded
   * from route validation check
   *
   * @returns a boolean
   */
  function isExceptUrl() {
    return excemptUrls.includes(router?.pathname)
  }

  const { isError: isErrorProject, error: projectError } = useProjectDetailQuery({ ref })

  const { data: organizations, isSuccess: orgsInitialized } = useOrganizationsQuery({
    enabled: isLoggedIn,
  })
  const organizationsRef = useLatest(organizations)

  useEffect(() => {
    // check if current route is excempted from route validation check
    if (isExceptUrl() || !isLoggedIn) return

    if (orgsInitialized && slug) {
      // Check validity of organization that user is trying to access
      const organizations = organizationsRef.current ?? []
      const isValidOrg = organizations.some((org) => org.slug === slug)

      if (!isValidOrg) {
        toast.error('You do not have access to this organization')
        router.push(DEFAULT_HOME)
        return
      }
    }
  }, [orgsInitialized])

  useEffect(() => {
    // check if current route is excempted from route validation check
    if (isExceptUrl() || !isLoggedIn) return

    // A successful request to project details will validate access to both project and branches
    if (!!ref && isErrorProject) {
      console.log('[SB2 debug] project error', {
        ref,
        code: projectError?.code,
        message: projectError?.message,
        name: (projectError as any)?.name,
        raw: projectError,
      })
      // 404 = project no longer exists (e.g. was deleted)
      // 400 = ref doesn't match the SB2 ref format (e.g. legacy "default" bookmark)
      // Neither is an access error — don't toast.
      if (projectError?.code !== 404 && projectError?.code !== 400) {
        toast.error('You do not have access to this project')
      }
      router.push(DEFAULT_HOME)
      return
    }
  }, [isErrorProject])

  useEffect(() => {
    if (ref !== undefined && id !== undefined) {
      if (router.pathname.endsWith('/sql/[id]') && id !== 'new') {
        setLastVisitedSnippet(id)
      } else if (router.pathname.endsWith('/editor/[id]')) {
        setLastVisitedTable(id)
      }
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ref, id])

  useEffect(() => {
    if (organization) {
      setLastVisitedOrganization(organization.slug)

      if (
        organization.organization_requires_mfa &&
        !isUserMFAEnabled &&
        router.pathname !== '/org/[slug]'
      ) {
        router.push(`/org/${organization.slug}`)
      }
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [organization])

  return <>{children}</>
}
