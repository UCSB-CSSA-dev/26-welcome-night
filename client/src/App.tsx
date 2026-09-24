import { BrowserRouter, Navigate, Route, Routes } from "react-router-dom";
import { Toaster } from "sonner";
import { HomePage } from "@/pages/HomePage";
import { AdminPage } from "@/pages/AdminPage";

export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<HomePage />} />
        <Route path="/admin" element={<AdminPage />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
      <Toaster
        position="top-center"
        richColors
        closeButton
        theme="light"
        toastOptions={{
          classNames: {
            toast: "font-sans",
          },
        }}
      />
    </BrowserRouter>
  );
}
