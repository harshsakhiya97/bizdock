import { BrowserRouter, Navigate, Route, Routes } from 'react-router'
import { AuthProvider } from '@/auth/AuthProvider'
import { RequireAuth } from '@/auth/RequireAuth'
import { AppLayout } from '@/layout/AppLayout'
import { DashboardPage } from '@/pages/Dashboard'
import { LoginPage } from '@/pages/Login'
import { ProfilePage } from '@/pages/Profile'
import { WhatsNewPage } from '@/pages/WhatsNew'
import { TenantDetailPage } from '@/tenants/TenantDetailPage'
import { TenantsPage } from '@/tenants/TenantsPage'

export default function App() {
  return (
    <AuthProvider>
      <BrowserRouter>
        <Routes>
          <Route path="/login" element={<LoginPage />} />
          <Route element={<RequireAuth />}>
            <Route element={<AppLayout />}>
              <Route path="/dashboard" element={<DashboardPage />} />
              <Route path="/clients" element={<TenantsPage />} />
              <Route path="/clients/:id" element={<TenantDetailPage />} />
              <Route path="/profile" element={<ProfilePage />} />
              <Route path="/whats-new" element={<WhatsNewPage />} />
            </Route>
          </Route>
          <Route path="*" element={<Navigate to="/dashboard" replace />} />
        </Routes>
      </BrowserRouter>
    </AuthProvider>
  )
}
