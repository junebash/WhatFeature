import { createRouter, createWebHashHistory } from 'vue-router'
import { session, whenSignedOut } from './session'

// Hash URLs (`/ui/#/projects/demo/flags`), so the server only ever serves index.html and its assets.
export const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: '/sign-in', name: 'sign-in', component: () => import('./views/SignInView.vue') },
    { path: '/', redirect: '/projects' },
    { path: '/projects', name: 'projects', component: () => import('./views/ProjectsView.vue') },
    { path: '/projects/:project', redirect: (to) => `/projects/${to.params.project}/flags` },
    { path: '/projects/:project/flags', name: 'flags', component: () => import('./views/FlagsView.vue') },
    { path: '/projects/:project/flags/:flag', name: 'flag', component: () => import('./views/FlagView.vue') },
    { path: '/projects/:project/evaluate', name: 'evaluate', component: () => import('./views/EvaluateView.vue') },
    { path: '/projects/:project/tracking', name: 'tracking', component: () => import('./views/TrackingView.vue') },
    { path: '/tokens', name: 'tokens', component: () => import('./views/TokensView.vue') },
    { path: '/audit', name: 'audit', component: () => import('./views/AuditView.vue') },
    { path: '/:rest(.*)*', redirect: '/projects' },
  ],
})

router.beforeEach((to) => {
  if (!session.token && to.name !== 'sign-in') {
    return { name: 'sign-in', query: { next: to.fullPath } }
  }
})

whenSignedOut(() => {
  const next = router.currentRoute.value.fullPath
  void router.push({ name: 'sign-in', query: next === '/sign-in' ? {} : { next } })
})
