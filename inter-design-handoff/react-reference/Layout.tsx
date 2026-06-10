import React from "react";
import { SidebarProvider, Sidebar, SidebarContent, SidebarGroup, SidebarGroupLabel, SidebarMenu, SidebarMenuItem, SidebarMenuButton } from "./components/ui/sidebar";
import { NavLink, Outlet, useLocation } from "react-router";
import { LayoutDashboard, Monitor, Key, Video, MessageSquare, Settings, Users, Calendar, Shield, Moon, Sun } from "lucide-react";
import { useTheme } from "./context/ThemeContext";

const navigation = [
  { name: "Dashboard", href: "/", icon: LayoutDashboard },
  {
    name: "Core Flows",
    items: [
      { name: "Connection Setup", href: "/screen/connection", icon: Monitor },
      { name: "Pre-Meeting Settings", href: "/screen/pre-meeting", icon: Settings },
      { name: "Green Room", href: "/screen/green-room", icon: Video },
    ]
  },
  {
    name: "Access",
    items: [
      { name: "Login & Register", href: "/screen/auth", icon: Key },
      { name: "Account & Settings", href: "/screen/account", icon: Key },
    ]
  },
  {
    name: "Live Session",
    items: [
      { name: "In-Call Window", href: "/screen/in-call", icon: Video },
      { name: "Host Controls View", href: "/screen/host-controls", icon: Shield },
      { name: "Lobby & Waiting", href: "/screen/lobby", icon: Users },
    ]
  },
  {
    name: "Collaboration",
    items: [
      { name: "Chat Panel", href: "/screen/chat", icon: MessageSquare },
      { name: "Q&A Panel", href: "/screen/qa", icon: MessageSquare },
      { name: "Poll Panel", href: "/screen/poll", icon: MessageSquare },
      { name: "Schedule Panel", href: "/screen/schedule", icon: Calendar },
    ]
  },
  {
    name: "Management",
    items: [
      { name: "Teams Panel", href: "/screen/teams", icon: Users },
    ]
  },
  {
    name: "Security",
    items: [
      { name: "Secure Interview", href: "/screen/secure", icon: Shield },
    ]
  }
];

export function AppLayout() {
  const location = useLocation();
  const { mode, toggle } = useTheme();

  return (
    <SidebarProvider>
      <div className="flex h-screen w-full bg-neutral-50 dark:bg-neutral-950 overflow-hidden font-sans">
        <Sidebar>
          <div className="flex h-14 items-center px-4 border-b border-sidebar-border">
            <div>
              <div className="font-semibold text-sm tracking-wide text-neutral-500">CATALOGUE</div>
              <div className="font-semibold text-base leading-tight">Inter Product UI</div>
            </div>
          </div>
          <SidebarContent>
            <SidebarGroup>
              <SidebarMenu>
                <SidebarMenuItem>
                  <SidebarMenuButton asChild isActive={location.pathname === "/"}>
                    <NavLink to="/">
                      <LayoutDashboard className="mr-2 h-4 w-4" />
                      <span>Overview</span>
                    </NavLink>
                  </SidebarMenuButton>
                </SidebarMenuItem>
              </SidebarMenu>
            </SidebarGroup>

            {navigation.slice(1).map((group) => (
              <SidebarGroup key={group.name}>
                <SidebarGroupLabel>{group.name}</SidebarGroupLabel>
                <SidebarMenu>
                  {group.items.map((item) => (
                    <SidebarMenuItem key={item.name}>
                      <SidebarMenuButton asChild isActive={location.pathname === item.href}>
                        <NavLink to={item.href}>
                          <item.icon className="mr-2 h-4 w-4" />
                          <span>{item.name}</span>
                        </NavLink>
                      </SidebarMenuButton>
                    </SidebarMenuItem>
                  ))}
                </SidebarMenu>
              </SidebarGroup>
            ))}
          </SidebarContent>

          {/* ── Theme Switcher ── pinned to sidebar footer */}
          <div className="flex-shrink-0 border-t border-sidebar-border p-3">
            {/* Dark (Obsidian Ink) / Light (Glitter) toggle */}
            <div className="flex items-center justify-between">
              <span className="text-xs font-medium text-muted-foreground">Appearance</span>
              <button
                onClick={toggle}
                className="flex items-center gap-1.5 text-xs font-semibold px-2.5 py-1.5 rounded-lg border border-border bg-background hover:bg-accent transition-colors"
              >
                {mode === "dark"
                  ? <><Sun className="w-3.5 h-3.5" /> Light</>
                  : <><Moon className="w-3.5 h-3.5" /> Dark</>
                }
              </button>
            </div>
          </div>
        </Sidebar>

        <main className="flex-1 flex flex-col h-full overflow-hidden relative">
          <Outlet />
        </main>
      </div>
    </SidebarProvider>
  );
}
