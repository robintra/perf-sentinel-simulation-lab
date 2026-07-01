<?php

namespace App\Controller;

use Doctrine\ORM\EntityManagerInterface;
use Symfony\Bundle\FrameworkBundle\Controller\AbstractController;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\Routing\Attribute\Route;

class HealthController extends AbstractController
{
    public function __construct(private EntityManagerInterface $em)
    {
    }

    // Liveness: cheap, no DB — the process is up.
    #[Route('/health/live', methods: ['GET'])]
    public function live(): JsonResponse
    {
        return new JsonResponse(['status' => 'UP']);
    }

    // Readiness: gated on a live DB round-trip.
    #[Route('/health/ready', methods: ['GET'])]
    public function ready(): JsonResponse
    {
        try {
            $this->em->getConnection()->executeQuery('SELECT 1');
            return new JsonResponse(['status' => 'UP']);
        } catch (\Throwable $e) {
            return new JsonResponse(['status' => 'DOWN'], 503);
        }
    }
}
